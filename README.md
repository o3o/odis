# odis

A small Redis/Valkey client library written in [Odin](https://odin-lang.org/).

## Status

This codebase was created by **Codex** and reviewed/checked by the **author**.

That means:

- the implementation was generated and iterated on by Codex
- the project direction, validation, and final review were provided by the author

## Features

- TCP connection to Redis-compatible servers
- optional `AUTH` during connect
- optional `SELECT` during connect
- RESP parsing for:
  - simple strings
  - errors
  - integers
  - bulk strings
  - arrays
  - null values
- convenience commands:
  - `PING`
  - `GET`
  - `SET`
  - `SET ... EX`
  - `DEL`
- generic `command` API for custom Redis commands
- example program with leak tracking
- automated tests, including randomized round-trip tests

## Project Layout

- `redis.odin`: library implementation
- `redis_test.odin`: automated tests
- `examples/verify_localhost.odin`: example against a local Redis/Valkey server
- `examples/reuse_reply_allocator.odin`: example that resets the same reply allocator between commands
- `examples/set_ex_separate_allocators.odin`: example that uses `set_ex` with implicit client allocator and explicit reply allocator
- `Makefile`: basic project commands

## Usage

```odin
package main

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import redis ".."

main :: proc() {
	reply_arena: vmem.Arena
	if arena_err := vmem.arena_init_growing(&reply_arena); arena_err != nil {
		fmt.println("arena init error:", arena_err)
		return
	}
	defer vmem.arena_destroy(&reply_arena)
	reply_allocator := vmem.arena_allocator(&reply_arena)

	client, err := redis.connect(redis.Config{
		address = "127.0.0.1:6379",
	})
	if err != .None {
		fmt.println("connect error:", err)
		return
	}
	defer redis.close(&client)

	reply, cmd_err := redis.set_ex(&client, "hello", "world", 60, reply_allocator)
	if cmd_err != .None {
		fmt.println("command error:", cmd_err)
		return
	}

	fmt.println(reply.kind, reply.text, reply.integer)
	mem.free_all(reply_allocator)
}
```

`destroy_reply` is still available for fine-grained cleanup, but it now accepts an explicit allocator:

```odin
redis.destroy_reply(&reply, reply_allocator)
```

If you want to reuse the same allocator across multiple commands, the intended pattern is:

```odin
mem.free_all(reply_allocator)
reply, err := redis.get(&client, "hello", reply_allocator)
```

After `free_all`, all previously returned replies allocated from `reply_allocator` are invalid and must not be used again. A complete runnable example is available in `examples/reuse_reply_allocator.odin`.

## Development

The repository includes a minimal `Makefile`.

```bash
make check
make test
make tags
make format
```

Equivalent commands:

```bash
odin check . -no-entry-point
odin test .
otag .
odinfmt -w .
```

## Running The Example

Start a local Redis or Valkey server on `127.0.0.1:6379`, then run:

```bash
odin run examples/verify_localhost.odin -file
```

The example performs a small end-to-end verification and checks for memory leaks with Odin's tracking allocator.

To run the per-request allocator reuse example:

```bash
odin run examples/reuse_reply_allocator.odin -file
```

To run the `set_ex` example that keeps the client allocator separate from the reply allocator:

```bash
odin run examples/set_ex_separate_allocators.odin -file
```

## Running Tests

With a local Redis or Valkey instance listening on `127.0.0.1:6379`:

```bash
odin test .
```

To run a single test:

```bash
odin test . -define:ODIN_TEST_NAMES=redis.test_random_roundtrip_has_no_leaks
```

## Notes

- `command` returns a `Reply` even when Redis returns an error reply
- in that case the returned error is `redis.Error.Server_Error`
- the raw server message is available in both `reply.text` and `client.last_server_error`

## License

This project is licensed under the MIT License.
See [LICENSE.md](LICENSE.md) for details.
