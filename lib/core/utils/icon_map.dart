import 'package:flutter/material.dart';

/// Maps a stable string key (stored on Product.iconKey) to an [IconData].
/// Using a fixed whitelist guarantees the icon exists in the bundled
/// MaterialIcons font - safe from tree-shaking surprises.
IconData iconFromKey(String? key) {
  if (key == null) return Icons.restaurant_rounded;
  return _iconByKey[key] ?? Icons.restaurant_rounded;
}

/// Every key in the whitelist, in declaration order. Backs the icon pickers in
/// the product and category forms so they can only produce valid keys.
List<String> get iconKeys => _iconByKey.keys.toList(growable: false);

const _iconByKey = <String, IconData>{
  // Generic / food
  'restaurant': Icons.restaurant_rounded,
  'restaurant_menu': Icons.restaurant_menu_rounded,
  'dinner_dining': Icons.dinner_dining_rounded,
  'lunch_dining': Icons.lunch_dining_rounded,
  'breakfast_dining': Icons.breakfast_dining_rounded,
  'rice_bowl': Icons.rice_bowl_rounded,
  'ramen_dining': Icons.ramen_dining_rounded,
  'kebab_dining': Icons.kebab_dining_rounded,
  'soup_kitchen': Icons.soup_kitchen_rounded,
  'bakery_dining': Icons.bakery_dining_rounded,
  'fastfood': Icons.fastfood_rounded,
  'local_pizza': Icons.local_pizza_rounded,
  'burger': Icons.lunch_dining_rounded,

  // Drinks
  'local_drink': Icons.local_drink_rounded,
  'water_drop': Icons.water_drop_rounded,
  'local_cafe': Icons.local_cafe_rounded,
  'local_bar': Icons.local_bar_rounded,
  'coffee': Icons.coffee_rounded,
  'tea': Icons.emoji_food_beverage_rounded,
  'wine_bar': Icons.wine_bar_rounded,

  // Dessert
  'icecream': Icons.icecream_rounded,
  'cake': Icons.cake_rounded,
  'cookie': Icons.cookie_rounded,

  // Misc
  'set_meal': Icons.set_meal_rounded,
  'tapas': Icons.tapas_rounded,
  'takeout_dining': Icons.takeout_dining_rounded,
};
