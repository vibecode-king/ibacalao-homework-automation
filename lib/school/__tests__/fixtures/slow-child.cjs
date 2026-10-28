process.stdin.resume();
setTimeout(() => {
  process.stdout.write('{"ok":false,"reason":"parser_error"}\n');
}, 1_000);
