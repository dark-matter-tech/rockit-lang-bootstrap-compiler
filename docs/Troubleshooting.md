# Troubleshooting

## Build Issues

### "No such module 'CryptoKit'" on Linux

**Cause:** CryptoKit is macOS-only. On Linux, the compiler uses `swift-crypto` (Apple's open-source implementation).

**Fix:** This should resolve automatically via `Package.swift`. If not:
```bash
swift package resolve
swift build
```

### "No such module 'Crypto'"

**Cause:** `swift-crypto` package not resolved.

**Fix:**
```bash
swift package clean
swift package resolve
swift build
```

### "pkg-config: package 'openssl' not found" on Linux

**Cause:** OpenSSL development headers not installed.

**Fix:**
```bash
# Ubuntu/Debian
sudo apt install libssl-dev pkg-config

# Verify
pkg-config --modversion openssl
```

### "clang: command not found"

**Cause:** clang is needed for native compilation (LLVM IR → binary).

**Fix:**
```bash
# macOS
xcode-select --install

# Linux
sudo apt install clang-15
sudo ln -sf /usr/bin/clang-15 /usr/bin/clang
```

### Build fails with out-of-memory

**Cause:** Debug and release builds coexist in `.build/`, consuming too much memory (common in CI containers).

**Fix:**
```bash
rm -rf .build/debug
swift build -c release
```

Or clean entirely:
```bash
swift package clean
swift build -c release
```

### "error: unable to load standard library for target"

**Cause:** Swift installation is incomplete or misconfigured.

**Fix:** Verify Swift installation:
```bash
swift --version
swift -print-target-info
```

If using Docker, ensure you're using an official Swift image:
```bash
docker run -it swift:5.10.1-jammy bash
```

## Test Issues

### Tests fail with "XCTAssertEqual failed"

**Cause:** A compiler change altered output behavior.

**Fix:** Run the specific test to see the diff:
```bash
swift test --filter "TestName" --verbose
```

Check if the change is intentional. If so, update the expected value. If not, fix the regression.

### Tests hang or timeout

**Cause:** Likely an infinite loop in the VM or coroutine scheduler.

**Fix:** Run with timeout:
```bash
timeout 60 swift test --filter "TestName"
```

If it's a coroutine test, check `Scheduler.swift` and `Coroutine.swift` for suspend/resume logic.

### "test_unsafe.rok" crashes Stage 0

**Cause:** Freestanding-mode tests use builtins (`Ptr`, `alloc`, `unsafe`) that only Stage 1 supports.

**Fix:** These tests are excluded from the default test scheme. Don't run them with Stage 0:
```bash
# Use the default scheme (excludes advanced/)
rockit test --scheme default

# Or run specific test files
rockit run tests/core/test_basics.rok
```

## Stage 1 Compilation Issues

### Stage 0 fails to compile command.rok

**Cause:** `command.rok` may be out of sync with source modules.

**Fix:** Regenerate `command.rok`:
```bash
cd self-hosted-rockit
bash build.sh
```

Then recompile:
```bash
cd ..
swift build -c release
.build/release/rockit build-native self-hosted-rockit/command.rok
```

### Stage 1 binary crashes on startup

**Cause:** Usually a runtime linkage issue or ARC bug.

**Fix:**
1. Check that `rockit_runtime.o` was built for the correct platform:
   ```bash
   file runtime/rockit_runtime.o
   ```
2. Rebuild the runtime:
   ```bash
   cd runtime/rockit && bash build.sh && cd ../..
   ```
3. Recompile with explicit runtime path:
   ```bash
   .build/release/rockit build-native self-hosted-rockit/command.rok \
       --runtime-path runtime/rockit_runtime.o
   ```

### "exit 138" when Stage 1 compiles certain patterns

**Cause:** Known Stage 1 bug — string concatenation in loops (`s = s + "x"`) can cause a crash (exit 138) in `llvmgen.rok`.

**Workaround:** Use `stringConcat()` builtin instead of `+` operator for string building in loops:
```rockit
// Instead of: s = s + item
s = stringConcat(s, item)
```

### Bootstrap verification fails (Stage 2 != Stage 3)

**Cause:** The compiler is not producing deterministic output, or a genuine issue.

**Fix:**
1. Ensure `command.rok` is freshly generated (`bash build.sh`)
2. Recompile Stage 1 from scratch
3. Run verification again:
   ```bash
   self-hosted-rockit/command verify-bootstrap
   ```
4. If it still fails, compare the bytecode files:
   ```bash
   xxd /tmp/stage2.rokb > /tmp/s2.hex
   xxd /tmp/stage3.rokb > /tmp/s3.hex
   diff /tmp/s2.hex /tmp/s3.hex
   ```

## CI Issues

### CI build takes too long

**Cause:** Building both debug and release, or running full bootstrap verification in CI.

**Fix:**
- Remove debug build before release: `rm -rf .build/debug`
- Use bytecode-only bootstrap in CI (full native bootstrap in release workflow only)
- Set `continue-on-error: true` for non-critical test steps

### "command.rok out of sync" in CI

**Cause:** Build identity values (git hash, timestamp) differ between local and CI.

**Fix:** The consistency check in CI filters out dynamic lines:
```bash
grep -v '^val ROCKIT_' command.rok > /tmp/filtered.rok
```

If this still fails, regenerate and commit `command.rok`:
```bash
cd self-hosted-rockit && bash build.sh && cd ..
git add self-hosted-rockit/command.rok
git commit -m "Regenerate command.rok"
```

### CI container OOM kill

**Cause:** The GitHub Actions / Gitea container has limited memory.

**Fix:**
- Delete debug artifacts: `rm -rf .build/debug`
- Avoid running memory-intensive tests (exclude `advanced/` directory)
- Don't coexist debug + release builds

## LSP Issues

### Language server doesn't start

**Cause:** Binary not built or wrong path.

**Fix:**
```bash
swift build -c release
.build/release/rockit lsp
# Should block, waiting for JSON-RPC input on stdin
```

### Editor doesn't show diagnostics

**Cause:** LSP client configuration issue.

**Fix:** Check that your editor is configured to run `.build/release/rockit lsp`. The LSP communicates via stdin/stdout using JSON-RPC. Verify with:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' | .build/release/rockit lsp
```

You should see a JSON response.

### Completions are slow

**Cause:** The LSP re-parses and type-checks on every keystroke.

**Fix:** This is expected for large files. The LSP uses incremental document sync to minimize work. For very large files (>1000 lines), consider splitting into modules.

## Runtime Issues

### "malloc: out of memory" at runtime

**Cause:** Memory leak — likely an ARC cycle (two objects retaining each other).

**Fix:** Use `weak` or `unowned` references to break cycles:
```rockit
class Node(val value: Int) {
    weak var parent: Node? = null
    var children: List<Node> = listCreate()
}
```

### Segfault in native binary

**Cause:** Usually a codegen bug (incorrect ARC, dangling pointer, or incorrect LLVM IR).

**Debug:**
1. Compile with debug info:
   ```bash
   .build/release/rockit build-native file.rok --debug
   ```
2. Run under lldb:
   ```bash
   lldb ./output
   (lldb) run
   (lldb) bt   # backtrace at crash point
   ```

### Actor deadlock

**Cause:** Actor sending message to itself, or circular message sends.

**Fix:** Avoid circular actor dependencies. Use `async` to break synchronous message chains:
```rockit
actor A {
    fun doWork(): Unit {
        // Don't call back to self synchronously
        async { self.continuation() }
    }
}
```
