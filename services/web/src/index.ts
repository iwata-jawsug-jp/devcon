export function greet(name = 'world'): string {
  return `Hello, ${name}!`;
}

function main(): void {
  console.log(greet());
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
