# Secure Unix Domain Socket Interprocess Communication

This design document outlines the strategy for securing communication between the Bigtable Ruby client and the Java Sidecar by using restricted Unix domain sockets and leveraging the directory isolation pattern.

## Reliability of `Dir.mktmpdir`'s Block Form
The block form of Ruby's `Dir.mktmpdir` is **highly reliable** for managing ephemeral resources like secure directories and Unix Domain sockets. 

Under the hood, Ruby wraps the `yield` statement in a `begin ... ensure` block. This guarantees that `FileUtils.remove_entry` is called on the directory when execution leaves the block. It cleans up the folder and any contained files (the socket) not only upon successful completion but also if an unhandled error or exception is raised inside the block. 

*Edge Case Note:* The only situations in which it would fail to clean up are catastrophic process terminations, such as the Ruby process receiving a `SIGKILL` (`kill -9`) or a hard system crash where the OS immediately halts the process without allowing `ensure` blocks to run.

## Proposed Changes

### Ruby Client Process Management

We will modify the core component responsible for spawning the Java sidecar process to create a secure, isolated folder with permissions set to `0700`.

#### [MODIFY] [Ruby Sidecar Spawner File]
- Require the `tmpdir` module.
- Wrap the entire lifecycle of the sidecar in `Dir.mktmpdir("sidecar-") do |secure_dir| ... end`.
- Inside the block, construct a predictable socket path: `socket_path = File.join(secure_dir, "grpc.sock")`.
- Pass this isolated `socket_path` down to the Java sidecar as a CLI argument or an Environment Variable.
- Any client attempting to communicate with the sidecar must be initialized with this socket path.

### Java Sidecar Netty Listener

#### [MODIFY] [Java Sidecar Entrypoint] (e.g. `BigtableProxyService.java` or `Sidecar.java`)
- Ensure the argument/option parsing receives the Unix Socket path from Ruby.
- Initialize the gRPC `Server` with Netty bound to the provided path.
- The Java process will inherit access to write the `.sock` file implicitly since it is running under the same user, but no permission modifications logic (`chmod`) need to be written in Java.

## Verification Plan

### Automated Tests
1. **Lifecycle Tests:** Run the Ruby test suite that initializes and tears down the sidecar. Assert that after the test is complete, there are no residual `/tmp/sidecar-*` directories or `.sock` files remaining.
2. **Exception Handling Tests:** Add a test case that injects a failure or throws an error during sidecar operation in Ruby. Verify that the `mktmpdir` cleanup (`at_exit` hook) successfully cleans up the socket folder despite the test aborting.
3. **Connectivity Tests:** Perform basic end-to-end integration tests over the Unix domain socket path confirming RPCs go through successfully.

### Cross-User Socket Access Verification

To verify the `0700` permission behavior enforced by `Dir.mktmpdir`, the following shell script (`test_daemon_access.sh`) was run to simulate access by an unauthorized user (`daemon`):

```bash
#!/bin/bash

# Create a secure temp directory using ruby
SECURE_DIR=$(ruby -r tmpdir -e 'print Dir.mktmpdir("sidecar-")')
echo "Created directory: $SECURE_DIR"
ls -ld $SECURE_DIR

# Create a file inside to simulate the socket
FILE_PATH="$SECURE_DIR/grpc.sock"
touch $FILE_PATH
echo "Created file: $FILE_PATH"
ls -l $FILE_PATH
echo ""

echo "--- Test 1: Can daemon user list the directory? ---"
sudo -u daemon ls -la $SECURE_DIR 2>&1

echo ""
echo "--- Test 2: Can daemon user read the file directly? ---"
sudo -u daemon cat $FILE_PATH 2>&1

echo ""
echo "Cleaning up..."
rm -rf $SECURE_DIR
echo "Done."
```

**Results:**

```text
Created directory: /tmp/sidecar-20260303-2544912-urtw5
drwx------ 2 justinuang primarygroup 40 Mar  3 14:10 /tmp/sidecar-20260303-2544912-urtw5
Created file: /tmp/sidecar-20260303-2544912-urtw5/grpc.sock
-rw-r--r-- 1 justinuang primarygroup 0 Mar  3 14:10 /tmp/sidecar-20260303-2544912-urtw5/grpc.sock

--- Test 1: Can daemon user list the directory? ---
ls: cannot open directory '/tmp/sidecar-20260303-2544912-urtw5': Permission denied

--- Test 2: Can daemon user read the file directly? ---
cat: /tmp/sidecar-20260303-2544912-urtw5/grpc.sock: Permission denied

Cleaning up...
Done.
```

These results confirm that the parent directory (`0700`) correctly prevents any unauthorized user from reading or interacting with the inner socket file, even if the file itself has looser permissions.

## Codebase Status & Recommendations

After reviewing the current `google-cloud-bigtable` implementation in `service.rb`:
- The codebase **already uses** `Dir.mktmpdir("bigtable-sidecar")` without a block (which correctly applies `0700` permissions by default).
- It cleans up the directory using an `at_exit` hook because the Java Sidecar process must run continuously in the background for the duration of the Ruby application lifecycle. 
- Using the `do |dir| ... end` block form of `mktmpdir` is **not feasible** here because the block would exit immediately and delete the directory, breaking the long-lived sidecar process.

**Conclusion:** The current code is already completely safe and correctly isolates the Unix socket. No code changes are required for the filesystem permissions.

### GCE VM Verification (Completed)

We verified the socket isolation on a live GCE VM (`ju-ruby-sidecar-c3-vm-east4`) running the sidecar process.

**Results:**
```console
justinuang_google_com@ju-ruby-sidecar-c3-vm-east4:~$ cat /tmp/bigtable-sidecar20260303-7008-571jjt/sidecar.sock
cat: /tmp/bigtable-sidecar20260303-7008-571jjt/sidecar.sock: No such device or address

justinuang_google_com@ju-ruby-sidecar-c3-vm-east4:~$ ls /tmp/bigtable-sidecar20260303-7008-571jjt/sidecar.sock
/tmp/bigtable-sidecar20260303-7008-571jjt/sidecar.sock

justinuang_google_com@ju-ruby-sidecar-c3-vm-east4:~$ sudo -n -u daemon ls /tmp/bigtable-sidecar20260303-7008-571jjt/sidecar.sock
ls: cannot access '/tmp/bigtable-sidecar20260303-7008-571jjt/sidecar.sock': Permission denied

justinuang_google_com@ju-ruby-sidecar-c3-vm-east4:~$ sudo -n -u daemon ls -l /tmp/bigtable-sidecar20260303-7008-571jjt/sidecar.sock
ls: cannot access '/tmp/bigtable-sidecar20260303-7008-571jjt/sidecar.sock': Permission denied

justinuang_google_com@ju-ruby-sidecar-c3-vm-east4:~$ ls -l /tmp/bigtable-sidecar20260303-7008-571jjt/sidecar.sock
srwxrwxr-x 1 justinuang_google_com justinuang_google_com 0 Mar  3 22:13 /tmp/bigtable-sidecar20260303-7008-571jjt/sidecar.sock
justinuang_google_com@ju-ruby-sidecar-c3-vm-east4:~$ sudo -n -u daemon nc -U /tmp/bigtable-sidecar20260303-7008-571jjt/sidecar.sock
nc: unix connect failed: Permission denied
```

This confirms:
1. The socket file itself has `srwxrwxr-x` permissions (indicated by the `s`).
2. The `cat` command fails because it's a socket stream, not a regular text file.
3. The `daemon` user is completely blocked from accessing or viewing the internal `.sock` file due to the `0700` permissions on the parent `/tmp/bigtable-sidecar...` directory. No unauthorized access is possible, even using socket connection tools like `nc`.
