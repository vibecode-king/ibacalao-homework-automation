process.stdin.resume();
setTimeout(() => {
  process.stdout.write('{"ok":true,"signature":{"tag":"article","classTokens":["assignment-card"]}}\n');
}, 3_200);
