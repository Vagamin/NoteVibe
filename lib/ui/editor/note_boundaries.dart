import 'package:flutter/material.dart';

const noteBoundaryStyles = {
  'full': 'На всю ширину',
  'short': 'Короткая по центру',
  'off': 'Отключены',
};
const noteBoundaryEdges = {
  'both': 'Начало и конец',
  'start': 'Только начало',
  'end': 'Только конец',
};

class NoteBoundary extends StatelessWidget {
  final String style;
  final String edges;
  final bool start;
  const NoteBoundary({super.key, required this.style, required this.edges, required this.start});

  @override
  Widget build(BuildContext context) {
    if (style == 'off' || (start && edges == 'end') || (!start && edges == 'start')) {
      return const SizedBox(height: 12);
    }
    return Center(child: SizedBox(
      width: style == 'short' ? 80 : double.infinity,
      child: const Divider(height: 24),
    ));
  }
}
