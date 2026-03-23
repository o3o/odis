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
- `Makefile`: basic project commands

## Usage

```odin
package main

import "core:fmt"
import redis ".."

main :: proc() {
	client, err := redis.connect(redis.Config{
		address = "127.0.0.1:6379",
	})
	if err != .None {
		fmt.println("connect error:", err)
		return
	}
	defer redis.close(&client)

	reply, cmd_err := redis.set_ex(&client, "hello", "world", 60)
	if cmd_err != .None {
		fmt.println("command error:", cmd_err)
		return
	}
	defer redis.destroy_reply(&reply)

	fmt.println(reply.kind, reply.text, reply.integer)
}
```

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
