import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/ui/editor/code_dialog.dart';

void main() {
  final examples = <String, String>{
    'Rust': 'fn main() { let value = 42; println!("{}", value); }',
    'Go': 'package main\nfunc main() { fmt.Println("Hello") }',
    'Kotlin': 'fun main() { println("Hello") }',
    'Swift': 'import SwiftUI\nlet name = "Hello"',
    'PHP': '<?php echo "Hello";',
    'Ruby': 'puts "Hello"',
    'PowerShell': 'Write-Host "Hello"',
    'Bash/Shell': '#!/bin/bash\necho "Hello"',
    'CSS': '.card { display: flex; color: red; }',
    'Python': 'def main():\n    print("Hello")',
    'SQL': 'SELECT name FROM notes',
    'TypeScript': 'const name: string = "Hello";',
    'JavaScript': 'const name = "Hello"; console.log(name);',
    'Dart': 'void main() { print("Hello"); }',
    'C#': 'using System;\nConsole.WriteLine("Hello");',
    'Java': 'public static void main(String[] args) { System.out.println("Hello"); }',
    'C/C++': '#include <stdio.h>\nint main() { return 0; }',
    'HTML/XML': '<html><body>Hello</body></html>',
    'Код': 'x = 42',
  };
  for (final example in examples.entries) {
    test('detects ${example.key}', () => expect(detectCodeLanguage(example.value), example.key));
  }
}
