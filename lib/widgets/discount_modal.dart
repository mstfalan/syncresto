import 'package:flutter/material.dart';

enum DiscountType { percentage, amount }

class DiscountModal extends StatefulWidget {
  final double currentTotal;
  final double? currentDiscount;
  final String? currentDiscountType;
  final Function(double discount, String type) onApply;
  final VoidCallback onRemove;
  final VoidCallback onClose;

  const DiscountModal({
    super.key,
    required this.currentTotal,
    this.currentDiscount,
    this.currentDiscountType,
    required this.onApply,
    required this.onRemove,
    required this.onClose,
  });

  @override
  State<DiscountModal> createState() => _DiscountModalState();
}

class _DiscountModalState extends State<DiscountModal> {
  DiscountType _discountType = DiscountType.percentage;
  final TextEditingController _valueController = TextEditingController();
  String? _errorMessage;

  // Hızlı indirim yüzdeleri
  final List<int> _quickPercentages = [5, 10, 15, 20, 25, 30];

  @override
  void initState() {
    super.initState();
    if (widget.currentDiscount != null && widget.currentDiscountType != null) {
      _discountType = widget.currentDiscountType == 'percentage'
          ? DiscountType.percentage
          : DiscountType.amount;
      _valueController.text = widget.currentDiscount!.toStringAsFixed(
          _discountType == DiscountType.percentage ? 0 : 2);
    }
  }

  @override
  void dispose() {
    _valueController.dispose();
    super.dispose();
  }

  double get _discountValue {
    final value = double.tryParse(_valueController.text) ?? 0;
    if (_discountType == DiscountType.percentage) {
      return (widget.currentTotal * value / 100);
    }
    return value;
  }

  double get _newTotal => widget.currentTotal - _discountValue;

  void _applyQuickPercentage(int percentage) {
    setState(() {
      _discountType = DiscountType.percentage;
      _valueController.text = percentage.toString();
      _errorMessage = null;
    });
  }

  void _applyDiscount() {
    final value = double.tryParse(_valueController.text);
    if (value == null || value <= 0) {
      setState(() => _errorMessage = 'Gecerli bir deger giriniz');
      return;
    }

    if (_discountType == DiscountType.percentage && value > 100) {
      setState(() => _errorMessage = 'Yuzde 100\'den fazla olamaz');
      return;
    }

    if (_discountType == DiscountType.amount && value > widget.currentTotal) {
      setState(() => _errorMessage = 'Toplam tutardan fazla olamaz');
      return;
    }

    widget.onApply(
      value,
      _discountType == DiscountType.percentage ? 'percentage' : 'amount',
    );
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 400,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Row(
              children: [
                const Icon(Icons.discount, color: Color(0xFFF59E0B), size: 28),
                const SizedBox(width: 12),
                const Text(
                  'Indirim Uygula',
                  style: TextStyle(
                    color: Color(0xFF1F2937),
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: widget.onClose,
                  icon: Icon(Icons.close, color: Colors.grey[600]),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // Current total
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Mevcut Toplam',
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 16,
                    ),
                  ),
                  Text(
                    '${widget.currentTotal.toStringAsFixed(2)} TL',
                    style: const TextStyle(
                      color: Color(0xFF1F2937),
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Discount type selector
            Row(
              children: [
                Expanded(
                  child: _buildTypeButton(
                    'Yuzde (%)',
                    DiscountType.percentage,
                    Icons.percent,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildTypeButton(
                    'Tutar (TL)',
                    DiscountType.amount,
                    Icons.attach_money,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // Quick percentages (only for percentage type)
            if (_discountType == DiscountType.percentage) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _quickPercentages.map((p) {
                  final isSelected = _valueController.text == p.toString();
                  return Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => _applyQuickPercentage(p),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? const Color(0xFFF59E0B)
                              : Colors.grey[100],
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isSelected ? const Color(0xFFF59E0B) : Colors.grey[300]!,
                          ),
                        ),
                        child: Text(
                          '%$p',
                          style: TextStyle(
                            color: isSelected ? Colors.white : Colors.grey[700],
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
            ],

            // Value input
            TextField(
              controller: _valueController,
              onChanged: (_) => setState(() => _errorMessage = null),
              style: const TextStyle(color: Color(0xFF1F2937), fontSize: 24),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                hintText: _discountType == DiscountType.percentage
                    ? 'Yuzde giriniz'
                    : 'Tutar giriniz',
                hintStyle: TextStyle(color: Colors.grey[500]),
                suffixText: _discountType == DiscountType.percentage ? '%' : 'TL',
                suffixStyle: const TextStyle(color: Color(0xFF1F2937), fontSize: 20),
                filled: true,
                fillColor: Colors.grey[100],
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey[300]!),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey[300]!),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFFF59E0B), width: 2),
                ),
                errorText: _errorMessage,
                errorStyle: const TextStyle(color: Colors.red),
              ),
            ),

            const SizedBox(height: 24),

            // Preview
            if (_valueController.text.isNotEmpty &&
                (double.tryParse(_valueController.text) ?? 0) > 0) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF16A34A).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF16A34A)),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Indirim',
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                        Text(
                          '-${_discountValue.toStringAsFixed(2)} TL',
                          style: const TextStyle(
                            color: Color(0xFFF59E0B),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Divider(color: Colors.grey[300], height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Yeni Toplam',
                          style: TextStyle(
                            color: Color(0xFF1F2937),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${_newTotal.toStringAsFixed(2)} TL',
                          style: const TextStyle(
                            color: Color(0xFF16A34A),
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],

            // Actions
            Row(
              children: [
                if (widget.currentDiscount != null)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        widget.onRemove();
                        widget.onClose();
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Text('Indirimi Kaldir'),
                    ),
                  ),
                if (widget.currentDiscount != null) const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _applyDiscount,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFF59E0B),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text(
                      'Uygula',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypeButton(String label, DiscountType type, IconData icon) {
    final isSelected = _discountType == type;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          setState(() {
            _discountType = type;
            _valueController.clear();
            _errorMessage = null;
          });
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFFF59E0B) : Colors.grey[100],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? const Color(0xFFF59E0B) : Colors.grey[300]!,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                color: isSelected ? Colors.white : Colors.grey[600],
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.grey[600],
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
