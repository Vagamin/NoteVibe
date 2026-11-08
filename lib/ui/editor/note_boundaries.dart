import 'package:flutter/material.dart';

const noteBoundaryEdges = {
  'off': 'Отключены',
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
    if (style == 'off' || edges == 'off' || (start && edges == 'end') || (!start && edges == 'start')) {
      return const SizedBox(height: 12);
    }
    return Center(child: SizedBox(
      width: double.infinity,
      child: const Divider(height: 24),
    ));
  }
}
