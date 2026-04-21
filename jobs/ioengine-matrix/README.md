# ioengine matrix

Each job file in this directory runs the *same* 70/30 random 8K workload but
with a different ioengine. Run them in sequence and diff the results to see
which engine is most disruptive to the pool, and how each compares to the
engine that qemu actually uses when serving a VM disk.

Suggested order:
1. `sync.fio`     — plain pread/pwrite; one syscall per I/O; lowest concurrency
2. `psync.fio`    — pread/pwrite, slightly different code path
3. `posixaio.fio` — POSIX aio (rarely used in the wild, useful sanity check)
4. `libaio.fio`   — classic Linux async I/O; what older qemu uses
5. `io-uring.fio` — modern async I/O; what Proxmox 7.2+ qemu uses by default

The global prelude pins `direct=1`, so all engines bypass the host page cache.
ZFS will still consult ARC because `direct=1` on a ZFS file does not imply
`primarycache=none`. Combine with the `no-cache` dataset if you want both.
