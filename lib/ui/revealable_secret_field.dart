import 'package:flutter/material.dart';

/// Masked text field with a trailing eye toggle to reveal plaintext.
class RevealableSecretField extends StatefulWidget {
  final String label;
  final TextEditingController controller;
  const RevealableSecretField({super.key, required this.label, required this.controller});

  @override
  State<RevealableSecretField> createState() => _RevealableSecretFieldState();
}

class _RevealableSecretFieldState extends State<RevealableSecretField> {
  bool _reveal = false;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      obscureText: !_reveal,
      decoration: InputDecoration(
        labelText: widget.label,
        border: const OutlineInputBorder(),
        isDense: true,
        suffixIcon: IconButton(
          icon: Icon(_reveal ? Icons.visibility_off : Icons.visibility),
          tooltip: _reveal ? 'Hide' : 'Show',
          onPressed: () => setState(() => _reveal = !_reveal),
        ),
      ),
    );
  }
}
