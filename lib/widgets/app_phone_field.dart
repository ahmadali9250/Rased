import 'package:flutter/material.dart';
import 'package:intl_phone_field/country_picker_dialog.dart';
import 'package:intl_phone_field/intl_phone_field.dart';
import 'package:intl_phone_field/phone_number.dart';

import '../services/app_language.dart';

/// The app's phone input: dark theme, Jordan first, and fully localized
/// (country names, search hint, validation message follow the UI language).
class AppPhoneField extends StatelessWidget {
  const AppPhoneField({
    super.key,
    this.controller,
    this.labelText,
    this.suffixIcon,
    this.onChanged,
    this.initialCountryCode = 'JO',
  });

  final TextEditingController? controller;
  final String? labelText;
  final Widget? suffixIcon;
  final ValueChanged<PhoneNumber>? onChanged;
  final String initialCountryCode;

  static const Color _gold = Color(0xFFFFD700);

  @override
  Widget build(BuildContext context) {
    final isArabic = context.isArabic;
    return IntlPhoneField(
      controller: controller,
      initialCountryCode: initialCountryCode,
      languageCode: isArabic ? 'ar' : 'en',
      textAlign: TextAlign.start,
      invalidNumberMessage:
          isArabic ? 'رقم الهاتف غير صالح' : 'Invalid mobile number',
      dropdownIcon: const Icon(Icons.arrow_drop_down, color: _gold),
      dropdownTextStyle: const TextStyle(color: Colors.white, fontSize: 16),
      style: const TextStyle(color: Colors.white),
      pickerDialogStyle: PickerDialogStyle(
        backgroundColor: const Color(0xFF1E1E1E),
        countryNameStyle: const TextStyle(color: Colors.white),
        countryCodeStyle: const TextStyle(color: Colors.white70),
        searchFieldCursorColor: _gold,
        searchFieldInputDecoration: InputDecoration(
          labelText: isArabic ? 'ابحث عن دولة' : 'Search country',
          labelStyle: const TextStyle(color: Colors.white54),
          prefixIcon: const Icon(Icons.search, color: Colors.white54),
          enabledBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: Colors.white38),
          ),
          focusedBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: _gold),
          ),
        ),
      ),
      decoration: InputDecoration(
        labelText: labelText,
        labelStyle: const TextStyle(color: Colors.white54),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: Colors.transparent,
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
          borderRadius: BorderRadius.circular(10),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: _gold),
          borderRadius: BorderRadius.circular(10),
        ),
      ),
      onChanged: onChanged,
    );
  }
}
