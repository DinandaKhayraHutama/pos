// Command verify-backoffice-crud proves the Fase 2B promise against a REAL
// running server: what an owner types into the Backoffice is what every till
// pulls.
//
// No unit test on either side can establish that. The panel's handlers, the
// domain writers, the sequence allocation, the pull feed and the device-auth
// cache are all exercised here in one request path each, the way a merchant and
// a tablet would exercise them. The single most valuable assertions:
//
//   - a product created in the browser arrives in the till's pull, with the
//     price the owner typed and nothing the till must not see;
//   - renaming a till in the browser reaches that till's own binding at once,
//     and closing its branch signs it out at once — not when a cache expires.
//
// It provisions a disposable merchant and deletes it in a defer.
//
//	justclick serve &
//	go run ./scripts/verify-backoffice-crud
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/bcrypt"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/tenancy"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
)

const (
	ownerPass   = "verify-owner-password"
	managerPass = "verify-manager-password"
)

var (
	csrfRE = regexp.MustCompile(`name="gorilla\.csrf\.Token" value="([^"]+)"`)
	codeRE = regexp.MustCompile(`class="code">([A-Z2-9]{12})<`)
	uuid   = `[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`

	failures int
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "fatal:", err)
		os.Exit(1)
	}
	if failures > 0 {
		fmt.Printf("\n%d check(s) FAILED\n", failures)
		os.Exit(1)
	}
	fmt.Println("\nall checks passed")
}

type session struct {
	client  *http.Client
	baseURL string
	csrf    string
}

func run() error {
	ctx := context.Background()
	baseURL := envOr("VERIFY_BASE_URL", "http://127.0.0.1:9000")

	owner, err := pgxpool.New(ctx, os.Getenv("MIGRATE_DATABASE_URL"))
	if err != nil {
		return err
	}
	defer owner.Close()

	pools, err := pg.OpenPools(ctx, os.Getenv("DATABASE_URL"), os.Getenv("UNSCOPED_DATABASE_URL"))
	if err != nil {
		return err
	}
	defer pools.Close()

	slug := fmt.Sprintf("vcrud-%d", time.Now().UnixNano())
	ownerEmail := slug + "-owner@justclick.test"
	managerEmail := slug + "-manager@justclick.test"

	provisioned, err := tenancy.Provision(ctx, pools, tenancy.Input{
		BusinessName: "Verify CRUD", Slug: slug, OwnerName: "Owner CRUD",
		OwnerEmail: ownerEmail, OwnerPassword: ownerPass,
	})
	if err != nil {
		return err
	}
	defer func() {
		if _, err := owner.Exec(context.Background(), `DELETE FROM tenants WHERE id = $1`, provisioned.TenantID); err != nil {
			fmt.Fprintln(os.Stderr, "cleanup failed:", err)
		}
	}()

	s, err := signIn(baseURL, ownerEmail, ownerPass)
	if err != nil {
		return err
	}

	// ---- outlets and registers -------------------------------------------

	fmt.Println("outlets and tills")

	status, _, body := s.post("/backoffice/outlets", url.Values{"name": {"Outlet CRUD"}, "address": {"Jl. Verifikasi 1"}})
	check("an outlet is created from the panel", status == http.StatusOK && strings.Contains(body, "Outlet CRUD"),
		"got %d: %s", status, truncate(body))
	outletID := firstMatch(regexp.MustCompile(`/backoffice/outlets/(`+uuid+`)"`), body)
	check("the new outlet links to its own page", outletID != "", "no outlet link in %s", truncate(body))

	status, _, body = s.post("/backoffice/outlets", url.Values{"name": {"Outlet CRUD"}})
	check("a duplicate outlet name is refused beside the field",
		status == http.StatusOK && strings.Contains(body, "sudah dipakai"), "got %d: %s", status, truncate(body))

	status, _, body = s.post("/backoffice/outlets/"+outletID+"/registers",
		url.Values{"name": {"Kasir 1"}, "table_service": {"on"}})
	registerID := firstMatch(regexp.MustCompile(`/registers/(`+uuid+`)"`), body)
	check("a till is created inside the outlet", status == http.StatusOK && registerID != "",
		"got %d: %s", status, truncate(body))

	status, body = s.get("/backoffice/devices")
	s.refresh(body)
	check("the devices page lists the new till", status == http.StatusOK && strings.Contains(body, "Kasir 1"),
		"got %d", status)

	status, _, body = s.post("/backoffice/registers/"+registerID+"/activation-code", url.Values{})
	code := firstMatch(codeRE, body)
	check("an activation code is issued for it", status == http.StatusOK && code != "", "got %d", status)

	clearActivationLimiter(ctx)
	till, err := activate(s.client, baseURL, code)
	if err != nil {
		return err
	}

	me := till.me()
	check("the till is bound to the till the panel made", me.Register.ID == registerID && me.Register.Name == "Kasir 1",
		"got %+v", me.Register)

	status, _, _ = s.post("/backoffice/outlets/"+outletID+"/registers/"+registerID,
		url.Values{"name": {"Kasir Depan"}, "table_service": {"on"}, "sort_order": {"0"}})
	check("the till is renamed in the panel", status == http.StatusOK, "got %d", status)
	check("the rename reaches the tablet's own binding at once, not after the cache expires",
		till.me().Register.Name == "Kasir Depan", "tablet still sees %q", till.me().Register.Name)

	// ---- catalogue -----------------------------------------------------------

	fmt.Println("catalogue")

	status, _, body = s.post("/backoffice/catalogue/categories", url.Values{"name": {"Minuman"}})
	categoryID := firstMatch(regexp.MustCompile(`/backoffice/catalogue/categories/(`+uuid+`)"`), body)
	check("a category is created", status == http.StatusOK && categoryID != "", "got %d: %s", status, truncate(body))

	status, _, body = s.post("/backoffice/catalogue/brands", url.Values{"name": {"Indomilk"}})
	brandID := firstMatch(regexp.MustCompile(`/backoffice/catalogue/brands/(`+uuid+`)"`), body)
	check("a brand is created", status == http.StatusOK && brandID != "", "got %d: %s", status, truncate(body))

	status, headers, body := s.post("/backoffice/catalogue/products", url.Values{
		"name": {"Kopi Susu"}, "category_id": {categoryID}, "price": {"25000.50"}, "icon_key": {"restaurant"},
	})
	check("a decimal price is refused beside the field, never guessed at",
		status == http.StatusOK && headers.Get("HX-Redirect") == "" && strings.Contains(body, "Harus rupiah bulat"),
		"got %d redirect=%q: %s", status, headers.Get("HX-Redirect"), truncate(body))

	status, headers, _ = s.post("/backoffice/catalogue/products", url.Values{
		"name": {"Kopi Susu"}, "category_id": {categoryID}, "brand_id": {brandID}, "price": {"25.000"}, "sku": {"KS-01"},
		"icon_key": {"restaurant"}, "available": {"on"},
	})
	productID := firstMatch(regexp.MustCompile(`/backoffice/catalogue/products/(`+uuid+`)$`), headers.Get("HX-Redirect"))
	check("a product is created and the panel moves to its page", status == http.StatusOK && productID != "",
		"got %d redirect=%q", status, headers.Get("HX-Redirect"))

	status, body = s.get("/backoffice/catalogue/products/" + productID)
	s.refresh(body)
	check("the product page renders with its price as typed", status == http.StatusOK && strings.Contains(body, `value="25000"`),
		"got %d", status)
	check("the product page renders with its brand selected",
		strings.Contains(body, `value="`+brandID+`" selected`), "brand not selected in %s", truncate(body))

	status, _, body = s.post("/backoffice/catalogue/products/"+productID+"/variants",
		url.Values{"name": {"Large"}, "price_delta": {"5.000"}})
	check("a variant is added inline", status == http.StatusOK && strings.Contains(body, `value="Large"`),
		"got %d: %s", status, truncate(body))

	status, headers, _ = s.post("/backoffice/catalogue/modifiers", url.Values{
		"name": {"Gula"}, "selection_type": {"single"}, "active": {"on"},
	})
	groupID := firstMatch(regexp.MustCompile(`/backoffice/catalogue/modifiers/(`+uuid+`)$`), headers.Get("HX-Redirect"))
	check("a modifier group is created", status == http.StatusOK && groupID != "", "got %d", status)

	optionRE := regexp.MustCompile(`/options/(` + uuid + `)"`)
	s.post("/backoffice/catalogue/modifiers/"+groupID+"/options", url.Values{"name": {"Normal"}, "active": {"on"}})
	_, _, body = s.post("/backoffice/catalogue/modifiers/"+groupID+"/options", url.Values{"name": {"Sedikit"}, "active": {"on"}})
	options := allMatches(optionRE, body)
	check("two options are added to it", len(options) == 2, "got %v", options)

	if len(options) == 2 {
		status, _, body = s.post("/backoffice/catalogue/products/"+productID+"/modifiers", url.Values{
			"group": {groupID}, "option": {options[0], options[1]}, "default": {options[0], options[1]},
		})
		check("two defaults in a single-choice group are refused, as the till would",
			status == http.StatusOK && strings.Contains(body, "hanya boleh punya 1 pilihan default"),
			"got %d: %s", status, truncate(body))

		status, _, _ = s.post("/backoffice/catalogue/products/"+productID+"/modifiers", url.Values{
			"group": {groupID}, "option": {options[0], options[1]}, "default": {options[0]},
		})
		check("a valid modifier configuration is saved", status == http.StatusOK, "got %d", status)
	}

	// ---- product image ----------------------------------------------------------

	fmt.Println("product image")

	status, body = s.upload("/backoffice/catalogue/products/"+productID+"/image", "image", "menu.svg",
		[]byte(`<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>`))
	check("an SVG is refused beside the upload field, never stored",
		status == http.StatusOK && strings.Contains(body, "Format gambar harus JPG, PNG, atau WebP"), "got %d: %s", status, truncate(body))

	imageCursor := till.cursor("products")
	status, body = s.upload("/backoffice/catalogue/products/"+productID+"/image", "image", "foto.jpg", portraitPhoto())
	check("a phone photo is uploaded from the product page",
		status == http.StatusOK && strings.Contains(body, `class="product-image"`), "got %d: %s", status, truncate(body))

	imageURL, _ := till.pullAfter("products", imageCursor)[productID]["image_url"].(string)
	check("the till pulls the image URL", strings.Contains(imageURL, "/media/products/"), "got %q", imageURL)

	if imageURL != "" {
		resp, err := s.client.Get(imageURL)
		if err != nil {
			return fmt.Errorf("fetch the published image: %w", err)
		}
		picture, _ := io.ReadAll(resp.Body)
		resp.Body.Close()

		check("the published URL serves the image", resp.StatusCode == http.StatusOK && resp.Header.Get("Content-Type") == "image/jpeg",
			"got %d %q", resp.StatusCode, resp.Header.Get("Content-Type"))
		check("it is cacheable for a year, because the name is its hash",
			resp.Header.Get("Cache-Control") == "public, max-age=31536000, immutable" && resp.Header.Get("X-Content-Type-Options") == "nosniff",
			"got %q / %q", resp.Header.Get("Cache-Control"), resp.Header.Get("X-Content-Type-Options"))
		check("the photo's location data is gone", !bytes.Contains(picture, []byte("Exif")), "EXIF survived")

		decoded, err := jpeg.Decode(bytes.NewReader(picture))
		upright := err == nil && decoded.Bounds().Dx() == 768 && decoded.Bounds().Dy() == 1024
		check("it arrives upright and no larger than 1024 px", upright, "err=%v", err)
		if upright {
			r, g, _, _ := decoded.At(748, 20).RGBA()
			check("turned the way the phone was held", r > 0xB000 && g < 0x5000, "marker not at the top-right")
		}

		missing := imageURL[:strings.LastIndex(imageURL, "/")+1] + strings.Repeat("0", 64) + ".jpg"
		resp, err = s.client.Get(missing)
		if err == nil {
			resp.Body.Close()
			check("a missing image is a 404 nobody caches", resp.StatusCode == http.StatusNotFound && resp.Header.Get("Cache-Control") == "",
				"got %d %q", resp.StatusCode, resp.Header.Get("Cache-Control"))
		}
		resp, err = s.client.Get(imageURL[:strings.Index(imageURL, "/media/")] + "/media/products/")
		if err == nil {
			resp.Body.Close()
			check("the image directory cannot be listed", resp.StatusCode == http.StatusNotFound, "got %d", resp.StatusCode)
		}
	}

	status, body = s.get("/backoffice/catalogue/products/" + productID)
	s.refresh(body)
	check("saving the product form keeps the image", status == http.StatusOK && strings.Contains(body, imageURL), "image gone from the page")

	imageCursor = till.cursor("products")
	status, _, _ = s.post("/backoffice/catalogue/products/"+productID+"/image/delete", url.Values{})
	removed := till.pullAfter("products", imageCursor)[productID]
	check("removing the image tells the till to fall back to its icon",
		status == http.StatusOK && removed != nil && removed["image_url"] == nil, "got %d: %v", status, removed)

	// ---- promos and staff ------------------------------------------------------

	fmt.Println("promos and staff")

	status, _, body = s.post("/backoffice/promos", url.Values{
		"name": {"Promo Cabang"}, "kind": {"amount"}, "value": {"5.000"}, "active": {"on"},
	})
	check("a promo scoped to no outlet is refused rather than read as everywhere",
		status == http.StatusOK && strings.Contains(body, "Pilih minimal satu outlet"), "got %d: %s", status, truncate(body))

	status, headers, _ = s.post("/backoffice/promos", url.Values{
		"name": {"Promo Cabang"}, "kind": {"amount"}, "value": {"5.000"}, "active": {"on"}, "outlets": {outletID},
	})
	promoID := firstMatch(regexp.MustCompile(`/backoffice/promos/(`+uuid+`)$`), headers.Get("HX-Redirect"))
	check("a promo scoped to one outlet is created", status == http.StatusOK && promoID != "", "got %d", status)

	status, headers, _ = s.post("/backoffice/staff", url.Values{"name": {"Sari"}, "role": {"cashier"}, "pin": {"1234"}})
	cashierID := firstMatch(regexp.MustCompile(`/backoffice/staff/(`+uuid+`)$`), headers.Get("HX-Redirect"))
	check("a cashier is created with a PIN", status == http.StatusOK && cashierID != "", "got %d", status)

	status, headers, _ = s.post("/backoffice/staff", url.Values{"name": {"Budi"}, "role": {"cashier"}, "pin": {"1234"}})
	check("a second cashier may share the same PIN",
		status == http.StatusOK && headers.Get("HX-Redirect") != "", "got %d redirect=%q", status, headers.Get("HX-Redirect"))

	status, _, body = s.post("/backoffice/staff", url.Values{"name": {"Citra"}, "role": {"cashier"}, "pin": {"98a7"}})
	check("a PIN that is not four digits is refused beside the field",
		status == http.StatusOK && strings.Contains(body, "PIN harus tepat 4 angka"), "got %d: %s", status, truncate(body))
	check("a refused PIN is not echoed back into the page", !strings.Contains(body, `value="98a7"`), "the PIN came back")

	// ---- Fase 3: roles and business settings ------------------------------------

	fmt.Println("roles and business settings")

	status, headers, _ = s.post("/backoffice/staff/roles", url.Values{
		"name": {"Gudang"}, "permissions": {"adjustStock", "viewDailySummary"}, "pos_access": {"on"},
	})
	roleID := firstMatch(regexp.MustCompile(`/backoffice/staff/roles/(`+uuid+`)$`), headers.Get("HX-Redirect"))
	check("a custom role is created", status == http.StatusOK && roleID != "", "got %d", status)

	// The till activated above never reported roles-v1: it would read a custom
	// role as a cashier who may sell, so none may be handed out yet.
	status, _, body = s.post("/backoffice/staff/"+cashierID, url.Values{"name": {"Sari"}, "role": {roleID}})
	check("a custom role is not handed out while a till cannot read it",
		status == http.StatusOK && strings.Contains(body, "belum mendukung peran kustom"), "got %d: %s", status, truncate(body))

	s.post("/backoffice/staff/roles", url.Values{
		"name": {"Terlalu Kuasa"}, "permissions": {"launchRockets"}, "pos_access": {"on"},
	})
	var unknown int
	_ = owner.QueryRow(ctx, `SELECT count(*) FROM roles WHERE tenant_id = $1 AND 'launchRockets' = ANY(permissions)`,
		provisioned.TenantID).Scan(&unknown)
	check("an unknown permission is never stored", unknown == 0, "found %d", unknown)

	_, body = s.get("/backoffice/settings")
	s.refresh(body)
	status, _, _ = s.post("/backoffice/settings/business", url.Values{
		"tax_rate": {"11"}, "tax_mode": {"exclusive"}, "service_rate": {"5"}, "service_taxable": {"on"},
		"rounding_unit": {"0"}, "rounding_mode": {"nearest"},
	})
	settingsRows := till.pull("business_settings")
	var business map[string]any
	for _, row := range settingsRows {
		business = row
	}
	check("the business settings reach the till", status == http.StatusOK && business != nil &&
		business["tax_rate_bp"] == float64(1100), "got %d %v", status, business)

	status, _, _ = s.post("/backoffice/settings/profile", url.Values{"name": {"Verify CRUD"}, "timezone": {"Asia/Jayapura"}})
	var zone string
	_ = owner.QueryRow(ctx, `SELECT timezone FROM tenants WHERE id = $1`, provisioned.TenantID).Scan(&zone)
	check("the owner moves the business to WIT", status == http.StatusOK && zone == "Asia/Jayapura",
		"got %d %q", status, zone)
	status, _, _ = s.post("/backoffice/settings/profile", url.Values{"name": {"Verify CRUD"}, "timezone": {"Europe/London"}})
	_ = owner.QueryRow(ctx, `SELECT timezone FROM tenants WHERE id = $1`, provisioned.TenantID).Scan(&zone)
	check("a zone outside the three Indonesian ones is refused", zone == "Asia/Jayapura", "got %d %q", status, zone)

	// ---- what the till pulls -------------------------------------------------

	fmt.Println("what the till pulls")

	outlets := till.pull("outlets")
	check("the outlet reaches the till", outlets[outletID]["name"] == "Outlet CRUD", "got %v", outlets[outletID])

	registers := till.pull("pos_registers")
	check("the renamed till reaches the feed", registers[registerID]["name"] == "Kasir Depan",
		"got %v", registers[registerID])

	categories := till.pull("categories")
	check("the category reaches the till", categories[categoryID]["name"] == "Minuman", "got %v", categories[categoryID])

	brands := till.pull("brands")
	check("the brand reaches the till", brands[brandID]["name"] == "Indomilk", "got %v", brands[brandID])

	products := till.pull("products")
	product := products[productID]
	check("the product reaches the till with the price the owner typed",
		product["price"] == float64(25_000) && product["sku"] == "KS-01", "got %v", product)
	check("the product's brand reaches the till", product["brand_id"] == brandID, "got %v", product["brand_id"])

	variants := till.pull("product_variants")
	var large map[string]any
	for _, v := range variants {
		if v["product_id"] == productID {
			large = v
		}
	}
	check("the variant reaches the till", large != nil && large["price_delta"] == float64(5_000), "got %v", large)

	groups := till.pull("modifier_groups")
	check("the modifier group reaches the till", groups[groupID]["selection_type"] == "single", "got %v", groups[groupID])

	scoping := till.pull("product_modifier_options")
	if len(options) == 2 {
		first, second := scoping[productID+"/"+options[0]], scoping[productID+"/"+options[1]]
		check("the product's option scoping reaches the till, default included",
			first["is_default"] == true && second["is_default"] == false, "got %v and %v", first, second)
	}

	promos := till.pull("promos")
	check("the promo reaches the till as scoped, never as company-wide",
		promos[promoID]["all_outlets"] == false && promos[promoID]["value"] == float64(5_000), "got %v", promos[promoID])
	check("its outlet scoping reaches the till", till.pull("promo_outlets")[promoID+"/"+outletID] != nil, "no scoping row")

	cashier := till.pull("employees")[cashierID]
	hash, _ := cashier["pin_hash"].(string)
	check("the cashier reaches the till with a PIN it can verify offline",
		strings.HasPrefix(hash, "$2a$10$") && bcrypt.CompareHashAndPassword([]byte(hash), []byte("1234")) == nil,
		"got %v", cashier)
	_, leakedEmail := cashier["email"]
	_, leakedPassword := cashier["password"]
	check("and with nothing a till must not hold", !leakedEmail && !leakedPassword,
		"got keys %v", cashier)

	// ---- stock (Fase 5) ---------------------------------------------------------

	fmt.Println("stock")

	// Fase 6: exercise HTTP forms, not only the domain service.
	floorPath := "/backoffice/outlets/" + outletID + "/tables"
	status, body = s.get(floorPath)
	check("the floor plan page renders", status == http.StatusOK && strings.Contains(body, "Status live"), "got %d", status)
	status, _, body = s.post(floorPath, url.Values{"name": {"Meja Teras"}, "area": {"Teras"}, "capacity": {"4"}, "pos_x": {"2"}, "pos_y": {"3"}, "sort_order": {"1"}})
	tableID := firstMatch(regexp.MustCompile(`/tables/(`+uuid+`)"`), body)
	check("a table is created through the form", status == http.StatusOK && tableID != "", "got %d: %s", status, truncate(body))
	check("the table definition reaches the till", till.pull("tables")[tableID]["area"] == "Teras", "area missing")
	status, _, body = s.post(floorPath, url.Values{"name": {"Invalid"}, "capacity": {"0"}})
	check("invalid seats are refused beside the form", status == http.StatusOK && strings.Contains(body, `class="error"`), "got %d: %s", status, truncate(body))
	status, _, _ = s.post(floorPath+"/"+tableID, url.Values{"name": {"Meja Jendela"}, "area": {"Dalam"}, "capacity": {"6"}, "sort_order": {"1"}})
	check("a table edit reaches the till", status == http.StatusOK && till.pull("tables")[tableID]["name"] == "Meja Jendela", "edit missing")
	status, body = s.get(floorPath + "/board")
	check("the read-only board reflects the plan", status == http.StatusOK && strings.Contains(body, "Meja Jendela"), "got %d", status)
	status, _, _ = s.post(floorPath+"/"+tableID+"/active", url.Values{"active": {""}})
	check("a retired table reaches the till", status == http.StatusOK && till.pull("tables")[tableID]["active"] == false, "retirement missing")
	status, _, _ = s.post(floorPath+"/"+tableID+"/delete", url.Values{})
	check("deletion publishes the table tombstone", status == http.StatusOK && till.pull("tables")[tableID]["deleted_at_ms"] != nil, "tombstone missing")
	var statusTombstone bool
	for _, row := range till.pull("table_status") {
		if row["table_id"] == tableID && row["deleted_at_ms"] != nil {
			statusTombstone = true
		}
	}
	check("deletion also publishes its status tombstone", statusTombstone, "status tombstone missing")

	stockPath := "/backoffice/stock/" + outletID + "/" + productID
	status, body = s.get("/backoffice/stock?outlet=" + outletID)
	s.refresh(body)
	check("the stock page lists the product at the new outlet",
		status == http.StatusOK && strings.Contains(body, stockPath), "got %d", status)

	status, _, body = s.post(stockPath+"/adjust", url.Values{"kind": {"received"}, "quantity": {"0"}})
	check("a delivery of nothing is refused beside the field",
		status == http.StatusOK && strings.Contains(body, "Jumlah harus"), "got %d: %s", status, truncate(body))

	status, headers, _ = s.post(stockPath+"/adjust", url.Values{"kind": {"received"}, "quantity": {"12"}, "note": {"Kiriman pagi"}})
	check("a delivery is booked from the panel", status == http.StatusOK && headers.Get("HX-Redirect") == stockPath,
		"got %d redirect=%q", status, headers.Get("HX-Redirect"))

	stockQty := func() (float64, bool) {
		for _, row := range till.pull("outlet_stock") {
			if row["product_id"] == productID {
				qty, ok := row["qty_on_hand"].(float64)
				return qty, ok
			}
		}
		return 0, false
	}
	qty, found := stockQty()
	check("the count reaches the till in the outlet", found && qty == 12, "found=%v qty=%v", found, qty)

	status, headers, _ = s.post(stockPath+"/count", url.Values{"counted": {"7"}})
	check("a stock count is saved from the panel", status == http.StatusOK && headers.Get("HX-Redirect") == stockPath,
		"got %d redirect=%q", status, headers.Get("HX-Redirect"))
	qty, found = stockQty()
	check("the counted quantity replaces the count on the till", found && qty == 7, "found=%v qty=%v", found, qty)

	var counted map[string]any
	for _, row := range till.pull("stock_movements") {
		if row["reason"] == "count" {
			counted = row
		}
	}
	check("the ledger row the till pulls says what the count changed",
		counted != nil && counted["delta_qty"] == float64(-5) && counted["counted_qty"] == float64(7) && counted["stock_seq"] != nil,
		"got %v", counted)

	status, body = s.get(stockPath)
	check("the product's stock page shows its ledger", status == http.StatusOK &&
		strings.Contains(body, "Stok opname") && strings.Contains(body, "Kiriman pagi"), "got %d", status)

	// ---- changes after the fact ------------------------------------------------

	fmt.Println("changes after the fact")

	cursor := till.cursor("products")
	status, _, body = s.post("/backoffice/catalogue/products/"+productID+"/availability", url.Values{"available": {""}})
	check("the sold-out switch flips its row", status == http.StatusOK && strings.Contains(body, "habis"),
		"got %d: %s", status, truncate(body))
	changed := till.pullAfter("products", cursor)
	check("the till learns the product is sold out from one new row",
		len(changed) == 1 && changed[productID]["available"] == false, "got %v", changed)

	cursor = till.cursor("products")
	status, body = s.upload("/backoffice/catalogue/products/import", "file", "harga.csv", []byte("sku;harga\nKS-01;27.500\n"))
	check("a price list is applied", status == http.StatusOK && strings.Contains(body, "1 harga berubah"),
		"got %d: %s", status, truncate(body))
	changed = till.pullAfter("products", cursor)
	check("the imported price reaches the till", changed[productID]["price"] == float64(27_500), "got %v", changed)

	status, body = s.upload("/backoffice/catalogue/products/import", "file", "harga.csv", []byte("sku,harga\nKS-01,30000\nTIDAK-ADA,1000\n"))
	check("a price list with one bad line changes nothing",
		status == http.StatusOK && strings.Contains(body, "tidak ada harga yang diubah"), "got %d: %s", status, truncate(body))
	check("and the till sees no change", len(till.pullAfter("products", till.cursor("products"))) == 0, "a row moved")

	// ---- catalogue import/export (Fase 2) --------------------------------------

	fmt.Println("catalogue import/export")

	status, exported := s.get("/backoffice/catalogue/products/export")
	check("the catalogue exports as CSV, header first with no title row",
		status == http.StatusOK && strings.Contains(exported[:min(200, len(exported))], "id,name,category_id"),
		"got %d: %s", status, truncate(exported))
	check("the export carries the product's stable id, sku and brand",
		strings.Contains(exported, productID) && strings.Contains(exported, "KS-01") && strings.Contains(exported, brandID),
		"got %s", truncate(exported))

	// Re-uploading the export completely unmodified must be a pure no-op —
	// "ekspor–impor tanpa menggandakan entitas", the phase's own pass
	// criterion, made concrete — and with nothing to apply, no confirm form
	// is even offered.
	status, body = s.upload("/backoffice/catalogue/products/import", "file", "produk.csv", []byte(exported))
	check("re-uploading the unmodified export previews as a pure no-op",
		status == http.StatusOK && strings.Contains(body, "0 produk baru, 0 diperbarui, 1 tidak berubah") &&
			strings.Contains(body, "Tidak ada yang perlu diterapkan"),
		"got %d: %s", status, truncate(body))
	check("and no confirm form is offered for nothing to apply",
		!strings.Contains(body, "file_b64"), "a confirm form appeared: %s", truncate(body))

	// A real change: reprice the existing product AND add a brand-new one in
	// the same file, by editing the export rather than typing UUIDs by hand —
	// the shape a merchant bulk-editing a downloaded export actually has.
	edited := strings.Replace(exported, ",27500,", ",29000,", 1)
	check("the price cell was actually found and replaced", edited != exported, "export did not contain ,27500,")
	edited += "," + "Es Teh," + categoryID + ",,,,ET-01,5000,,,,restaurant,0,ya,tidak\n"

	status, body = s.upload("/backoffice/catalogue/products/import", "file", "produk.csv", []byte(edited))
	check("a file that both updates and creates previews with both counts",
		status == http.StatusOK && strings.Contains(body, "1 produk baru, 1 diperbarui, 0 tidak berubah"),
		"got %d: %s", status, truncate(body))

	fileB64 := firstMatch(regexp.MustCompile(`name="file_b64" value="([^"]*)"`), body)
	fileSHA256 := firstMatch(regexp.MustCompile(`name="file_sha256" value="([^"]*)"`), body)
	check("the preview carries the file forward to confirm", fileB64 != "", "no file_b64 in %s", truncate(body))

	cursor = till.cursor("products")
	status, _, body = s.post("/backoffice/catalogue/products/import/confirm", url.Values{"file_b64": {fileB64}, "file_sha256": {fileSHA256}})
	check("the preview is confirmed and applied",
		status == http.StatusOK && strings.Contains(body, "1 produk baru, 1 diperbarui, 0 tidak berubah"),
		"got %d: %s", status, truncate(body))

	changed = till.pullAfter("products", cursor)
	check("the repriced product reaches the till", changed[productID]["price"] == float64(29_000), "got %v", changed[productID])
	var newProductID string
	for id, p := range changed {
		if p["sku"] == "ET-01" {
			newProductID = id
		}
	}
	check("the new product from the same file also reaches the till",
		newProductID != "" && changed[newProductID]["name"] == "Es Teh" && changed[newProductID]["price"] == float64(5_000),
		"got %v", changed)

	status, body = s.upload("/backoffice/catalogue/products/import", "file", "bad.csv", []byte("id,name,fantasi\n"+productID+",X,Y\n"))
	check("an unknown column is refused by name, not silently ignored",
		status == http.StatusOK && strings.Contains(body, "fantasi") && strings.Contains(body, "tidak dikenal"),
		"got %d: %s", status, truncate(body))

	// Three columns, not the legacy two — this is the general importer, and
	// its header lacks name/category_id, so a row with no existing match
	// cannot become a product.
	status, body = s.upload("/backoffice/catalogue/products/import", "file", "bad2.csv",
		[]byte("sku,price,description\nNEW-SKU-NOT-CREATABLE,1000,x\n"))
	check("a create-shaped row is refused when the header cannot create",
		status == http.StatusOK && strings.Contains(body, "kolom"),
		"got %d: %s", status, truncate(body))

	// ---- customers -----------------------------------------------------------

	fmt.Println("customers")
	cursor = till.cursor("customers")
	status, _, _ = s.post("/backoffice/customers", url.Values{"name": {"Sari"}, "phone": {"0812-3456"}, "email": {"sari@example.test"}})
	status, body = s.get("/backoffice/customers?q=Sari")
	customerID := firstMatch(regexp.MustCompile(`/backoffice/customers/(`+uuid+`)`), body)
	check("a customer is created and searchable", status == http.StatusOK && customerID != "", "got %d: %s", status, truncate(body))
	changed = till.pullAfter("customers", cursor)
	check("the customer reaches the till feed", changed[customerID]["name"] == "Sari", "got %v", changed[customerID])
	status, exportedCustomers := s.get("/backoffice/customers/export")
	check("customers export with stable ids", status == http.StatusOK && strings.Contains(exportedCustomers, customerID) && strings.Contains(exportedCustomers, "Sari"), "got %d: %s", status, truncate(exportedCustomers))
	var exportAudits int
	if err := owner.QueryRow(ctx, `SELECT count(*) FROM customer_export_events WHERE tenant_id=$1`, provisioned.TenantID).Scan(&exportAudits); err != nil {
		return err
	}
	check("exporting customer personal data writes one audit row", exportAudits == 1, "got %d", exportAudits)
	status, _ = s.upload("/backoffice/customers/import", "file", "pelanggan.csv", []byte(exportedCustomers))
	check("an unchanged customer export imports without duplication", status == http.StatusOK, "got %d", status)
	status, _, _ = s.post("/backoffice/customers", url.Values{"name": {"Sari Duplikat"}, "phone": {"0812 3456"}})
	status, body = s.get("/backoffice/customers?q=Sari")
	loserID := ""
	for _, candidate := range allMatches(regexp.MustCompile(`/backoffice/customers/(`+uuid+`)`), body) {
		if candidate != customerID {
			loserID = candidate
			break
		}
	}
	check("duplicate contacts are visibly flagged", status == http.StatusOK && loserID != "" && strings.Contains(body, "kontak duplikat"), "got %d: %s", status, truncate(body))
	if loserID != "" {
		cursor = till.cursor("customers")
		status, _, _ = s.post("/backoffice/customers/"+loserID+"/merge", url.Values{"winner_id": {customerID}})
		check("an explicit merge tombstones the loser", status == http.StatusOK, "got %d", status)
		changed = till.pullAfter("customers", cursor)
		check("the merged customer reaches the till as a tombstone", changed[loserID]["deleted_at_ms"] != nil, "got %v", changed[loserID])
	}

	// ---- a manager's view ------------------------------------------------------

	fmt.Println("a manager's view")

	status, headers, _ = s.post("/backoffice/staff", url.Values{
		"name": {"Manajer"}, "role": {"manager"}, "email": {managerEmail}, "pin": {"5678"},
	})
	managerID := firstMatch(regexp.MustCompile(`/backoffice/staff/(`+uuid+`)$`), headers.Get("HX-Redirect"))
	check("a manager is created", status == http.StatusOK && managerID != "", "got %d", status)

	status, _, _ = s.post("/backoffice/staff/"+managerID+"/password", url.Values{"password": {managerPass}})
	check("the manager is given a Backoffice password", status == http.StatusOK, "got %d", status)

	manager, err := signIn(baseURL, managerEmail, managerPass)
	if err != nil {
		return err
	}

	status, body = manager.get("/backoffice/catalogue/products")
	check("a manager cannot open the catalogue", status == http.StatusForbidden, "got %d", status)
	check("and is told so on a whole page", strings.Contains(body, "Tidak diizinkan"), "got %s", truncate(body))

	status, body = manager.get("/backoffice/outlets")
	manager.refresh(body)
	check("a manager can open the outlets", status == http.StatusOK, "got %d", status)
	check("and the nav offers only what the manager may open",
		strings.Contains(body, `href="/backoffice/outlets"`) && !strings.Contains(body, `href="/backoffice/catalogue/products"`),
		"nav does not match permissions")
	check("stock is in the manager's nav, as adjusting stock is theirs",
		strings.Contains(body, `href="/backoffice/stock"`), "no stock link")
	status, _ = manager.get("/backoffice/stock")
	check("a manager can open stock", status == http.StatusOK, "got %d", status)
	status, body = manager.get("/backoffice/customers")
	check("a manager can manage customers", status == http.StatusOK && strings.Contains(body, "Pelanggan"), "got %d", status)

	status, _, _ = manager.post("/backoffice/outlets/"+outletID+"/active", url.Values{"active": {""}})
	check("the manager closes the branch", status == http.StatusOK, "got %d", status)
	status, _ = till.getMe()
	check("the branch's till is signed out at once", status == http.StatusUnauthorized, "got %d", status)

	// ---- every page renders ----------------------------------------------------

	fmt.Println("every page renders")

	for _, path := range []string{
		"/backoffice/catalogue/categories", "/backoffice/catalogue/categories/" + categoryID,
		"/backoffice/catalogue/brands", "/backoffice/catalogue/brands/" + brandID,
		"/backoffice/catalogue/products", "/backoffice/catalogue/products/new",
		"/backoffice/catalogue/products/import", "/backoffice/catalogue/products?q=kopi",
		"/backoffice/catalogue/modifiers", "/backoffice/catalogue/modifiers/" + groupID,
		"/backoffice/promos", "/backoffice/promos/new", "/backoffice/promos/" + promoID,
		"/backoffice/staff", "/backoffice/staff/new", "/backoffice/staff/" + cashierID,
		"/backoffice/outlets", "/backoffice/outlets/" + outletID, "/backoffice/devices",
		"/backoffice/customers", "/backoffice/customers/" + customerID,
		floorPath,
		"/backoffice/stock", "/backoffice/stock?outlet=" + outletID + "&q=kopi", stockPath,
		"/backoffice/settings", "/backoffice/settings/outlets", "/backoffice/settings/outlets/" + outletID,
		"/backoffice/settings/sales-types", "/backoffice/settings/payments", "/backoffice/discounts",
		"/backoffice/staff/roles", "/backoffice/staff/roles/new", "/backoffice/staff/roles/" + roleID,
		"/backoffice/account",
	} {
		status, _ := s.get(path)
		check(path+" renders", status == http.StatusOK, "got %d", status)
	}

	status, _ = s.get("/backoffice/catalogue/products/00000000-0000-0000-0000-000000000000")
	check("an unknown product is a 404, not a 500", status == http.StatusNotFound, "got %d", status)
	status, _ = s.get("/backoffice/catalogue/products/not-a-uuid")
	check("a malformed id is a 404, not a 500", status == http.StatusNotFound, "got %d", status)

	// ---- the account (Fase 3) --------------------------------------------------

	fmt.Println("the account")

	const newPass = "verify-owner-new-password"
	_, body = s.get("/backoffice/account")
	s.refresh(body)
	s.post("/backoffice/account/password", url.Values{"current_password": {"not-the-password"}, "password": {newPass}})
	_, err = signIn(baseURL, ownerEmail, newPass)
	check("a wrong current password changes nothing", err != nil, "the new password was accepted")
	status, _, _ = s.post("/backoffice/account/password", url.Values{"current_password": {ownerPass}, "password": {newPass}})
	_, err = signIn(baseURL, ownerEmail, newPass)
	check("the owner changes their own password", status == http.StatusOK && err == nil, "got %d, %v", status, err)

	return nil
}

// ---- panel session ----------------------------------------------------------

func signIn(baseURL, email, password string) (*session, error) {
	jar, _ := cookiejar.New(nil)
	client := &http.Client{
		Jar: jar, Timeout: 15 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	// Caddy issues from its own local CA in development. Only ever against localhost.
	if os.Getenv("VERIFY_INSECURE_TLS") == "1" {
		client.Transport = &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}} //nolint:gosec
	}

	s := &session{client: client, baseURL: baseURL}

	_, body := s.get("/backoffice/login")
	s.refresh(body)

	form := url.Values{"email": {email}, "password": {password}, "gorilla.csrf.Token": {s.csrf}}
	req, _ := http.NewRequest(http.MethodPost, baseURL+"/backoffice/login", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	s.browser(req)
	status, _, _ := s.send(req)
	if status != http.StatusSeeOther {
		return nil, fmt.Errorf("sign in as %s: got %d", email, status)
	}

	_, body = s.get("/backoffice/devices")
	s.refresh(body)
	return s, nil
}

func (s *session) refresh(body string) {
	if token := firstMatch(csrfRE, body); token != "" {
		s.csrf = token
	}
}

func (s *session) get(path string) (int, string) {
	req, _ := http.NewRequest(http.MethodGet, s.baseURL+path, nil)
	status, _, body := s.send(req)
	return status, body
}

// post sends what HTMX sends: the form url-encoded, the token as a header taken
// from hx-headers on <body>, and the HX-Request marker.
func (s *session) post(path string, form url.Values) (int, http.Header, string) {
	req, _ := http.NewRequest(http.MethodPost, s.baseURL+path, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("X-CSRF-Token", s.csrf)
	req.Header.Set("HX-Request", "true")
	s.browser(req)
	return s.send(req)
}

func (s *session) upload(path, field, filename string, content []byte) (int, string) {
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	part, _ := w.CreateFormFile(field, filename)
	part.Write(content)
	w.Close()

	req, _ := http.NewRequest(http.MethodPost, s.baseURL+path, &buf)
	req.Header.Set("Content-Type", w.FormDataContentType())
	req.Header.Set("X-CSRF-Token", s.csrf)
	req.Header.Set("HX-Request", "true")
	s.browser(req)
	status, _, body := s.send(req)
	return status, body
}

// browser supplies the Origin a real browser sends on a same-origin POST;
// without it the CSRF middleware refuses the request before any handler runs.
func (s *session) browser(req *http.Request) {
	origin := req.URL.Scheme + "://" + req.URL.Host
	req.Header.Set("Origin", origin)
	req.Header.Set("Referer", origin+"/backoffice/")
}

func (s *session) send(req *http.Request) (int, http.Header, string) {
	resp, err := s.client.Do(req)
	if err != nil {
		return 0, http.Header{}, err.Error()
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, resp.Header, string(body)
}

// ---- the till ---------------------------------------------------------------

type tablet struct {
	client  *http.Client
	baseURL string
	token   string
}

type binding struct {
	Register struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	} `json:"pos_register"`
}

func activate(client *http.Client, baseURL, code string) (*tablet, error) {
	raw, _ := json.Marshal(map[string]any{"code": code, "device_uuid": "verify-crud-tablet"})
	req, _ := http.NewRequest(http.MethodPost, baseURL+"/api/v2/devices/activate", bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var out struct {
		Data struct {
			Token string `json:"token"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil || out.Data.Token == "" {
		return nil, fmt.Errorf("activate with a panel-issued code: HTTP %d", resp.StatusCode)
	}

	return &tablet{client: client, baseURL: baseURL, token: out.Data.Token}, nil
}

func (t *tablet) do(path string) (int, []byte) {
	req, _ := http.NewRequest(http.MethodGet, t.baseURL+path, nil)
	req.Header.Set("Authorization", "Bearer "+t.token)
	req.Header.Set("X-Schema-Version", fmt.Sprint(syncfeed.SchemaVersion))

	resp, err := t.client.Do(req)
	if err != nil {
		return 0, nil
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, body
}

func (t *tablet) getMe() (int, binding) {
	status, body := t.do("/api/v2/devices/me")
	var out struct {
		Data binding `json:"data"`
	}
	json.Unmarshal(body, &out)
	return status, out.Data
}

func (t *tablet) me() binding {
	_, b := t.getMe()
	return b
}

func (t *tablet) cursor(entity string) int64 {
	_, body := t.do("/api/v2/sync/changes")
	var out struct {
		Cursors map[string]int64 `json:"cursors"`
	}
	json.Unmarshal(body, &out)
	return out.Cursors[entity]
}

func (t *tablet) pull(entity string) map[string]map[string]any { return t.pullAfter(entity, 0) }

// pullAfter pages an entity from a cursor, the way the till does, and keys the
// rows by their published key — id, or the pair for the join feeds.
func (t *tablet) pullAfter(entity string, after int64) map[string]map[string]any {
	out := map[string]map[string]any{}
	for page := 0; page < 50; page++ {
		_, body := t.do(fmt.Sprintf("/api/v2/sync/pull?entity=%s&after_seq=%d&limit=500", entity, after))

		var decoded struct {
			Rows    []map[string]any `json:"rows"`
			NextSeq int64            `json:"next_seq"`
			HasMore bool             `json:"has_more"`
		}
		if json.Unmarshal(body, &decoded) != nil {
			return out
		}
		for _, row := range decoded.Rows {
			out[rowKey(row)] = row
		}

		after = decoded.NextSeq
		if !decoded.HasMore {
			return out
		}
	}
	return out
}

func rowKey(row map[string]any) string {
	if id, ok := row["id"].(string); ok {
		return id
	}
	var parts []string
	for _, k := range []string{"table_id", "product_id", "promo_id", "group_id", "option_id", "outlet_id"} {
		if v, ok := row[k].(string); ok {
			parts = append(parts, v)
		}
	}
	return strings.Join(parts, "/")
}

// portraitPhoto is what a phone writes when held upright: pixels stored landscape
// (1600×1200) with EXIF orientation 6, and a red block in the stored top-left
// that should end up top-right once the server turns it the right way.
func portraitPhoto() []byte {
	img := image.NewRGBA(image.Rect(0, 0, 1600, 1200))
	for y := 0; y < 1200; y++ {
		for x := 0; x < 1600; x++ {
			c := color.RGBA{R: 30, G: 120, B: 200, A: 255}
			if x < 200 && y < 150 {
				c = color.RGBA{R: 255, A: 255}
			}
			img.SetRGBA(x, y, c)
		}
	}

	var buf bytes.Buffer
	jpeg.Encode(&buf, img, &jpeg.Options{Quality: 90})
	raw := buf.Bytes()

	tiff := make([]byte, 26)
	copy(tiff, "MM")
	binary.BigEndian.PutUint16(tiff[2:], 42)
	binary.BigEndian.PutUint32(tiff[4:], 8)
	binary.BigEndian.PutUint16(tiff[8:], 1)
	binary.BigEndian.PutUint16(tiff[10:], 0x0112)
	binary.BigEndian.PutUint16(tiff[12:], 3)
	binary.BigEndian.PutUint32(tiff[14:], 1)
	binary.BigEndian.PutUint16(tiff[18:], 6)

	payload := append(append([]byte("Exif"), 0, 0), tiff...)
	segment := []byte{0xFF, 0xE1, 0, 0}
	binary.BigEndian.PutUint16(segment[2:], uint16(len(payload)+2))

	out := append([]byte{}, raw[:2]...)
	out = append(out, segment...)
	out = append(out, payload...)
	return append(out, raw[2:]...)
}

// ---- helpers ------------------------------------------------------------------

func clearActivationLimiter(ctx context.Context) {
	rdb, err := redisx.Open(ctx, os.Getenv("REDIS_URL"))
	if err != nil {
		return
	}
	defer rdb.Close()

	iter := rdb.Scan(ctx, 0, "rl:act:*", 100).Iterator()
	for iter.Next(ctx) {
		rdb.Del(ctx, iter.Val())
	}
}

func firstMatch(re *regexp.Regexp, s string) string {
	if m := re.FindStringSubmatch(s); len(m) > 1 {
		return m[1]
	}
	return ""
}

func allMatches(re *regexp.Regexp, s string) []string {
	var out []string
	seen := map[string]bool{}
	for _, m := range re.FindAllStringSubmatch(s, -1) {
		if !seen[m[1]] {
			seen[m[1]] = true
			out = append(out, m[1])
		}
	}
	return out
}

func truncate(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if len(s) > 240 {
		return s[:240] + "…"
	}
	return s
}

func check(name string, ok bool, format string, args ...any) {
	if ok {
		fmt.Printf("  PASS  %s\n", name)
		return
	}

	failures++
	fmt.Printf("  FAIL  %s: %s\n", name, fmt.Sprintf(format, args...))
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
