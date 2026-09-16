package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/platform"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/config"
)

// platformAdmin manages super admins. It is a CLI and not a screen on purpose:
// the first admin cannot be created from a panel that needs an admin to sign
// in, and a lost phone is recovered by someone with shell access to the server.
func platformAdmin(cfg config.Config, logger *slog.Logger, command string, args []string) error {
	fs := flag.NewFlagSet("platform admin "+command, flag.ContinueOnError)
	name := fs.String("name", "", "the admin's name (create)")
	email := fs.String("email", "", "the admin's email")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *email == "" {
		return errors.New("--email is required")
	}

	ctx := context.Background()
	pools, err := openPools(ctx, cfg)
	if err != nil {
		return err
	}
	defer pools.Close()
	svc := platform.NewService(pools, platform.Options{Logger: logger})

	switch command {
	case "create":
		// Generated rather than typed on the command line: an argument lands in
		// shell history, a durable place for a live credential to sit.
		password, err := randomPassword()
		if err != nil {
			return err
		}
		admin, err := svc.CreateAdmin(ctx, *name, *email, password)
		if err != nil {
			return err
		}
		fmt.Printf("super admin created\n  id        : %s\n  sign in as: %s\n  password  : %s\n\n"+
			"This password is shown once and is not stored anywhere in plaintext.\n"+
			"Two-factor sign-in is set up at the first sign-in to /platform.\n", admin.ID, admin.Email, password)
		return nil
	case "reset-totp":
		if err := svc.ResetTOTP(ctx, *email); err != nil {
			return err
		}
		fmt.Printf("two-factor sign-in reset for %s; it is set up again at the next sign-in\n", *email)
		return nil
	case "deactivate", "activate":
		if err := svc.SetAdminActive(ctx, *email, command == "activate"); err != nil {
			return err
		}
		fmt.Printf("%s: %sd\n", *email, command)
		return nil
	default:
		return errors.New(usage)
	}
}
