package redis

import "core:mem"
import "core:net"
import "core:strconv"
import "core:strings"

Error :: enum i32 {
	None,
	Not_Connected,
	Invalid_Argument,
	Dial_Failed,
	Send_Failed,
	Receive_Failed,
	Unexpected_EOF,
	Invalid_Reply,
	Integer_Parse_Failed,
	Server_Error,
}

Config :: struct {
	address:  string,
	password: string,
	db:       int,
}

default_config :: proc() -> Config {
	return Config{address = "127.0.0.1:6379", password = "", db = 0}
}

Reply_Kind :: enum i32 {
	Simple_String,
	Error,
	Integer,
	Bulk_String,
	Array,
	Null,
}

Reply :: struct {
	kind:     Reply_Kind,
	text:     string,
	integer:  i64,
	elements: [dynamic]Reply,
}

Client :: struct {
	socket:            net.TCP_Socket,
	connected:         bool,
	allocator:         mem.Allocator,
	buffer:            [dynamic]byte,
	buffer_start:      int,
	last_server_error: string,
}

/*
Recursively frees a Redis reply.

Deallocates the associated text and any nested replies stored inside arrays.

Inputs:
- reply: reply to destroy
- allocator: allocator used to build the reply

Returns: no values
*/
destroy_reply :: proc(reply: ^Reply, allocator := context.allocator) {
	delete(reply.text, allocator)
	for i in 0 ..< len(reply.elements) {
		destroy_reply(&reply.elements[i], allocator)
	}
	delete(reply.elements)
	reply^ = {}
}

/*
Closes the Redis client and frees the local buffer.

It also resets the last server error stored on the client.

Inputs:
- client: client to close

Returns: no values
*/
close :: proc(client: ^Client) {
	if client.connected {
		net.close(client.socket)
	}
	client.connected = false
	delete(client.buffer)
	client.buffer = nil
	client.buffer_start = 0
	delete(client.last_server_error, client.allocator)
	client.last_server_error = ""
}

/*
Creates a Redis connection using an explicit configuration.

It also applies any `AUTH` and `SELECT` commands required by the configuration.

Inputs:
- config: connection configuration
- allocator: allocator used for client-owned memory

Returns: connected client and optional error
*/
connect_with_config :: proc(
	config: Config,
	allocator := context.allocator,
) -> (
	client: Client,
	err: Error,
) {
	address := config.address
	if len(address) == 0 {
		address = "127.0.0.1:6379"
	}

	socket, dial_err := net.dial_tcp(address)
	if dial_err != nil {
		return {}, .Dial_Failed
	}

	client.socket = socket
	client.connected = true
	client.allocator = allocator
	client.buffer = make([dynamic]byte, 0, 0, allocator)

	if len(config.password) > 0 {
		auth_reply, auth_err := command(&client, []string{"AUTH", config.password}, allocator)
		if auth_err != .None {
			close(&client)
			return {}, auth_err
		}
		defer destroy_reply(&auth_reply, allocator)
		if auth_reply.kind == .Error {
			client.last_server_error = strings.clone(auth_reply.text, client.allocator)
			close(&client)
			return {}, .Server_Error
		}
	}

	if config.db != 0 {
		db_buf: [32]byte
		db_text := strconv.write_int(db_buf[:], i64(config.db), 10)
		select_reply, select_err := command(&client, []string{"SELECT", db_text}, allocator)
		if select_err != .None {
			close(&client)
			return {}, select_err
		}
		defer destroy_reply(&select_reply, allocator)
		if select_reply.kind == .Error {
			client.last_server_error = strings.clone(select_reply.text, client.allocator)
			close(&client)
			return {}, .Server_Error
		}
	}

	return client, .None
}

/*
Creates a Redis connection using the default configuration.

It uses `127.0.0.1:6379` with no authentication and no additional `SELECT`.

Inputs:
- allocator: allocator used for client-owned memory

Returns: connected client and optional error
*/
connect_default :: proc(allocator := context.allocator) -> (Client, Error) {
	return connect_with_config(default_config(), allocator)
}

connect :: proc {
	connect_default,
	connect_with_config,
}

/*
Sends a `PING` command to the Redis server.

If `message` is provided, Redis returns it as the reply payload.

Inputs:
- client: connected Redis client
- message: optional ping payload
- allocator: allocator used for the returned reply

Returns: server reply and optional error
*/
ping :: proc(client: ^Client, message := "", allocator := context.allocator) -> (Reply, Error) {
	if len(message) == 0 {
		return command(client, []string{"PING"}, allocator)
	}
	return command(client, []string{"PING", message}, allocator)
}

/*
Reads the value of a Redis key.

Internally it sends the `GET` command.

Inputs:
- client: connected Redis client
- key: key to read
- allocator: allocator used for the returned reply

Returns: server reply and optional error
*/
get :: proc(client: ^Client, key: string, allocator := context.allocator) -> (Reply, Error) {
	return command(client, []string{"GET", key}, allocator)
}

/*
Writes a value to a Redis key.

Internally it sends the `SET` command.

Inputs:
- client: connected Redis client
- key: key to write
- value: value to store
- allocator: allocator used for the returned reply

Returns: server reply and optional error
*/
set :: proc(
	client: ^Client,
	key, value: string,
	allocator := context.allocator,
) -> (
	Reply,
	Error,
) {
	return command(client, []string{"SET", key, value}, allocator)
}

/*
Writes a value to a Redis key with an expiration in seconds.

Internally it sends the `SET key value EX seconds` command.

Inputs:
- client: connected Redis client
- key: key to write
- value: value to store
- seconds: TTL expressed in seconds
- allocator: allocator used for the returned reply

Returns: server reply and optional error
*/
set_ex :: proc(
	client: ^Client,
	key, value: string,
	seconds: int,
	allocator := context.allocator,
) -> (
	Reply,
	Error,
) {
	if seconds <= 0 {
		return {}, .Invalid_Argument
	}

	seconds_buf: [32]byte
	seconds_text := strconv.write_int(seconds_buf[:], i64(seconds), 10)
	return command(client, []string{"SET", key, value, "EX", seconds_text}, allocator)
}

/*
Deletes one or more Redis keys.

It dynamically builds the `DEL` command using all provided keys.

Inputs:
- client: connected Redis client
- keys: keys to delete
- allocator: allocator used for the returned reply

Returns: server reply and optional error
*/
del_many :: proc(
	client: ^Client,
	keys: []string,
	allocator := context.allocator,
) -> (
	Reply,
	Error,
) {
	if !client.connected {
		return {}, .Not_Connected
	}

	args := make([]string, len(keys) + 1, client.allocator)
	defer delete(args, client.allocator)
	args[0] = "DEL"
	for key, i in keys {
		args[i + 1] = key
	}
	return command(client, args, allocator)
}

/*
Deletes a single Redis key.

Inputs:
- client: connected Redis client
- key: key to delete
- allocator: allocator used for the returned reply

Returns: server reply and optional error
*/
del_one :: proc(client: ^Client, key: string, allocator := context.allocator) -> (Reply, Error) {
	return del_many(client, []string{key}, allocator)
}

del :: proc {
	del_one,
	del_many,
}

/*
Returns the integer value represented by a Redis reply.

It accepts native RESP integers and textual replies containing base-10 integers.
Any unsupported kind or parse failure returns zero.

Inputs:
- reply: reply to convert

Returns: converted integer, or zero on errors
*/
reply_to_int :: proc(reply: Reply) -> int {
	switch reply.kind {
	case .Integer:
		return int(reply.integer)
	case .Bulk_String, .Simple_String:
		value, ok := strconv.parse_int(reply.text, 10)
		if !ok {
			return 0
		}
		return int(value)
	case .Error, .Array, .Null:
		return 0
	}
	return 0
}

/*
Returns the boolean value represented by a Redis reply.

It accepts native RESP integers and textual replies parseable as booleans.
Any unsupported kind or parse failure returns false.

Inputs:
- reply: reply to convert

Returns: converted boolean, or false on errors
*/
reply_to_bool :: proc(reply: Reply) -> bool {
	switch reply.kind {
	case .Integer:
		return reply.integer != 0
	case .Bulk_String, .Simple_String:
		value, ok := strconv.parse_bool(reply.text)
		if !ok {
			return false
		}
		return value
	case .Error, .Array, .Null:
		return false
	}
	return false
}

/*
Returns the floating-point value represented by a Redis reply.

It accepts native RESP integers and textual replies parseable as `f64`.
Any unsupported kind or parse failure returns 0.0.

Inputs:
- reply: reply to convert

Returns: converted float, or 0.0 on errors
*/
reply_to_f64 :: proc(reply: Reply) -> f64 {
	switch reply.kind {
	case .Integer:
		return f64(reply.integer)
	case .Bulk_String, .Simple_String:
		value, ok := strconv.parse_f64(reply.text)
		if !ok {
			return 0.0
		}
		return value
	case .Error, .Array, .Null:
		return 0.0
	}
	return 0.0
}

/*
Sends a generic Redis command.

It serializes the arguments as RESP, sends them on the socket, and reads the reply.

Inputs:
- client: connected Redis client
- args: command arguments, with the command name in position zero
- allocator: allocator used for the returned reply

Returns: server reply and optional error
*/
command :: proc(
	client: ^Client,
	args: []string,
	allocator := context.allocator,
) -> (
	Reply,
	Error,
) {
	if !client.connected {
		return {}, .Not_Connected
	}
	if len(args) == 0 {
		return {}, .Invalid_Argument
	}

	delete(client.last_server_error, client.allocator)
	client.last_server_error = ""

	payload := encode_command(args, client.allocator)
	defer delete(payload)

	written, send_err := net.send_tcp(client.socket, payload[:])
	if send_err != nil || written != len(payload) {
		return {}, .Send_Failed
	}

	reply, reply_err := read_reply(client, allocator)
	if reply_err == .Server_Error {
		client.last_server_error = strings.clone(reply.text, client.allocator)
	}
	return reply, reply_err
}

/*
Encodes a Redis command in RESP format.

The result is ready to be sent directly over the TCP socket.

Inputs:
- args: Redis command arguments
- allocator: allocator used for the serialized payload

Returns: dynamic buffer containing the serialized payload
*/
encode_command :: proc(args: []string, allocator := context.allocator) -> [dynamic]byte {
	prev_allocator := context.allocator
	context.allocator = allocator
	defer context.allocator = prev_allocator

	builder := strings.builder_make(allocator)
	defer delete(builder.buf)

	strings.write_byte(&builder, '*')
	strings.write_int(&builder, len(args))
	strings.write_string(&builder, "\r\n")

	for arg in args {
		strings.write_byte(&builder, '$')
		strings.write_int(&builder, len(arg))
		strings.write_string(&builder, "\r\n")
		strings.write_string(&builder, arg)
		strings.write_string(&builder, "\r\n")
	}

	result := make([dynamic]byte, len(builder.buf), len(builder.buf), allocator)
	copy(result[:], builder.buf[:])
	return result
}

/*
Reads a Redis reply from the client's input buffer.

It recognizes the main RESP prefixes and delegates to specialized parsers when needed.

Inputs:
- client: connected Redis client
- allocator: allocator used for the returned reply tree

Returns: decoded reply and optional error
*/
read_reply :: proc(client: ^Client, allocator := context.allocator) -> (Reply, Error) {
	if err := ensure_buffered(client, 1); err != .None {
		return {}, err
	}

	prefix := client.buffer[client.buffer_start]
	client.buffer_start += 1

	switch prefix {
	case '+':
		line, err := read_line(client, allocator)
		if err != .None {
			return {}, err
		}
		defer delete(line, allocator)
		return Reply{kind = .Simple_String, text = strings.clone(line, allocator)}, .None
	case '-':
		line, err := read_line(client, allocator)
		if err != .None {
			return {}, err
		}
		defer delete(line, allocator)
		return Reply{kind = .Error, text = strings.clone(line, allocator)}, .Server_Error
	case ':':
		line, err := read_line(client, allocator)
		if err != .None {
			return {}, err
		}
		defer delete(line, allocator)
		value, ok := strconv.parse_int(line, 10)
		if !ok {
			return {}, .Integer_Parse_Failed
		}
		return Reply{kind = .Integer, integer = i64(value)}, .None
	case '$':
		return read_bulk_string_reply(client, allocator)
	case '*':
		return read_array_reply(client, allocator)
	case:
		return {}, .Invalid_Reply
	}
}

/*
Reads a RESP bulk string.

It also handles the special `null bulk string` case.

Inputs:
- client: connected Redis client
- allocator: allocator used for the returned reply

Returns: bulk string or null reply and optional error
*/
read_bulk_string_reply :: proc(client: ^Client, allocator := context.allocator) -> (Reply, Error) {
	line, err := read_line(client, allocator)
	if err != .None {
		return {}, err
	}
	defer delete(line, allocator)

	size, ok := strconv.parse_int(line, 10)
	if !ok {
		return {}, .Integer_Parse_Failed
	}
	if size == -1 {
		return Reply{kind = .Null}, .None
	}
	if size < 0 {
		return {}, .Invalid_Reply
	}

	total := size + 2
	if err := ensure_buffered(client, total); err != .None {
		return {}, err
	}

	start := client.buffer_start
	stop := start + size
	if client.buffer[stop] != '\r' || client.buffer[stop + 1] != '\n' {
		return {}, .Invalid_Reply
	}

	text := strings.clone(string(client.buffer[start:stop]), allocator)
	client.buffer_start += total
	compact_buffer(client)

	return Reply{kind = .Bulk_String, text = text}, .None
}

/*
Reads a RESP array reply.

Each element is read recursively through `read_reply`.

Inputs:
- client: connected Redis client
- allocator: allocator used for the returned reply tree

Returns: array or null reply and optional error
*/
read_array_reply :: proc(client: ^Client, allocator := context.allocator) -> (Reply, Error) {
	line, err := read_line(client, allocator)
	if err != .None {
		return {}, err
	}
	defer delete(line, allocator)

	count, ok := strconv.parse_int(line, 10)
	if !ok {
		return {}, .Integer_Parse_Failed
	}
	if count == -1 {
		return Reply{kind = .Null}, .None
	}
	if count < 0 {
		return {}, .Invalid_Reply
	}

	elements := make([dynamic]Reply, count, count, allocator)
	for i in 0 ..< count {
		item, item_err := read_reply(client, allocator)
		if item_err != .None && item_err != .Server_Error {
			for j in 0 ..< i {
				destroy_reply(&elements[j], allocator)
			}
			delete(elements)
			return {}, item_err
		}
		elements[i] = item
	}

	return Reply{kind = .Array, elements = elements}, .None
}

/*
Reads a RESP line terminated by CRLF.

The returned string is an allocated copy of the parsed content.

Inputs:
- client: connected Redis client
- allocator: allocator used for the returned line copy

Returns: read line and optional error
*/
read_line :: proc(client: ^Client, allocator := context.allocator) -> (string, Error) {
	for {
		for i in client.buffer_start ..< len(client.buffer) - 1 {
			if client.buffer[i] == '\r' && client.buffer[i + 1] == '\n' {
				line := strings.clone(string(client.buffer[client.buffer_start:i]), allocator)
				client.buffer_start = i + 2
				compact_buffer(client)
				return line, .None
			}
		}

		if err := recv_more(client); err != .None {
			return "", err
		}
	}
}

/*
Ensures that the client's buffer contains at least `needed` readable bytes.

If the available data is insufficient, it performs additional socket reads.

Inputs:
- client: connected Redis client
- needed: minimum number of required bytes

Returns: optional receive or protocol error
*/
ensure_buffered :: proc(client: ^Client, needed: int) -> Error {
	for len(client.buffer) - client.buffer_start < needed {
		if err := recv_more(client); err != .None {
			return err
		}
	}
	return .None
}

/*
Reads more bytes from the socket and appends them to the client's buffer.

It compacts the buffer first when appropriate to reduce copies and unnecessary growth.

Inputs:
- client: connected Redis client

Returns: optional receive error
*/
recv_more :: proc(client: ^Client) -> Error {
	if !client.connected {
		return .Not_Connected
	}

	compact_buffer(client)

	temp: [4096]byte
	n, recv_err := net.recv_tcp(client.socket, temp[:])
	if recv_err != nil {
		return .Receive_Failed
	}
	if n == 0 {
		return .Unexpected_EOF
	}

	prev_allocator := context.allocator
	context.allocator = client.allocator
	defer context.allocator = prev_allocator
	append(&client.buffer, ..temp[:n])
	return .None
}

/*
Compacts the client's buffer by moving unread bytes to the front.

This prevents `buffer_start` from growing indefinitely during long reads.

Inputs:
- client: connected Redis client

Returns: no values
*/
compact_buffer :: proc(client: ^Client) {
	if client.buffer_start <= 0 {
		return
	}
	if client.buffer_start >= len(client.buffer) {
		clear(&client.buffer)
		client.buffer_start = 0
		return
	}
	if client.buffer_start < 1024 && client.buffer_start * 2 < len(client.buffer) {
		return
	}

	remaining := len(client.buffer) - client.buffer_start
	copy(client.buffer[:remaining], client.buffer[client.buffer_start:])
	resize(&client.buffer, remaining)
	client.buffer_start = 0
}
