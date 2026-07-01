package redis

import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:strings"
import "core:testing"
import "core:time"

TEST_REDIS_ADDR :: "127.0.0.1:6379"
ALPHABET :: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"

test_client_context :: struct {
	client: Client,
	key:    string,
}

destroy_test_client_context :: proc(data: rawptr) {
	ctx := (^test_client_context)(data)
	if ctx.key != "" && ctx.client.connected {
		reply, err := del(&ctx.client, []string{ctx.key})
		if err == .None || err == .Server_Error {
			destroy_reply(&reply)
		}
		delete(ctx.key, context.allocator)
	}
	delete(ctx.client.buffer)
	if ctx.client.connected {
		close(&ctx.client)
	}
	free(ctx)
}

connect_test_client :: proc(t: ^testing.T) -> ^test_client_context {
	client, err := connect(Config{address = TEST_REDIS_ADDR})
	if !testing.expectf(
		t,
		err == .None,
		"unable to connect to redis at %s: %v",
		TEST_REDIS_ADDR,
		err,
	) {
		return nil
	}

	ctx := new(test_client_context)
	ctx.client = client
	testing.cleanup(t, destroy_test_client_context, ctx)
	return ctx
}

connect_test_client_no_cleanup :: proc(t: ^testing.T) -> ^test_client_context {
	client, err := connect(Config{address = TEST_REDIS_ADDR})
	if !testing.expectf(
		t,
		err == .None,
		"unable to connect to redis at %s: %v",
		TEST_REDIS_ADDR,
		err,
	) {
		return nil
	}

	ctx := new(test_client_context)
	ctx.client = client
	return ctx
}

random_string :: proc(length: int, gen: rand.Generator) -> string {
	alphabet := ALPHABET
	buf := make([]byte, length)
	defer delete(buf)

	for i in 0 ..< length {
		buf[i] = alphabet[rand.int_max(len(alphabet), gen)]
	}

	return strings.clone(string(buf))
}

random_key :: proc(prefix: string, gen: rand.Generator) -> string {
	suffix := random_string(24, gen)
	defer delete(suffix)
	return strings.concatenate({prefix, suffix})
}

cleanup_key :: proc(ctx: ^test_client_context, key: string) {
	reply, err := del(&ctx.client, []string{key})
	if err == .None || err == .Server_Error {
		destroy_reply(&reply)
	}
}

assert_ok_reply :: proc(
	t: ^testing.T,
	reply: Reply,
	err: Error,
	expected_kind: Reply_Kind,
) -> bool {
	if !testing.expect_value(t, err, Error.None) {
		return false
	}
	return testing.expect_value(t, reply.kind, expected_kind)
}

@(test)
test_command_rejects_empty_args :: proc(t: ^testing.T) {
	client := Client{}
	reply_1, err_1 := command(&client, nil)
	defer destroy_reply(&reply_1)

	testing.expect_value(t, err_1, Error.Not_Connected)

	client.connected = true
	reply_2, err_2 := command(&client, nil)
	defer destroy_reply(&reply_2)

	testing.expect_value(t, err_2, Error.Invalid_Argument)
}

@(test)
test_del_single_key_not_connected :: proc(t: ^testing.T) {
	client := Client{}
	reply, err := del(&client, "odis:test:key")
	defer destroy_reply(&reply)

	testing.expect_value(t, err, Error.Not_Connected)
}

@(test)
test_reply_to_int :: proc(t: ^testing.T) {
	testing.expect_value(t, reply_to_int(Reply{kind = .Integer, integer = 42}), 42)
	testing.expect_value(t, reply_to_int(Reply{kind = .Bulk_String, text = "17"}), 17)
	testing.expect_value(t, reply_to_int(Reply{kind = .Simple_String, text = "-5"}), -5)
	testing.expect_value(t, reply_to_int(Reply{kind = .Bulk_String, text = "x"}), 0)
	testing.expect_value(t, reply_to_int(Reply{kind = .Error, text = "ERR nope"}), 0)
	testing.expect_value(t, reply_to_int(Reply{kind = .Null}), 0)
}

@(test)
test_reply_to_bool :: proc(t: ^testing.T) {
	testing.expect_value(t, reply_to_bool(Reply{kind = .Integer, integer = 1}), true)
	testing.expect_value(t, reply_to_bool(Reply{kind = .Integer, integer = 0}), false)
	testing.expect_value(t, reply_to_bool(Reply{kind = .Bulk_String, text = "true"}), true)
	testing.expect_value(t, reply_to_bool(Reply{kind = .Bulk_String, text = "t"}), true)
	testing.expect_value(t, reply_to_bool(Reply{kind = .Bulk_String, text = "TRUE"}), true)
	testing.expect_value(t, reply_to_bool(Reply{kind = .Bulk_String, text = "TR"}), false)
	testing.expect_value(t, reply_to_bool(Reply{kind = .Bulk_String, text = "T"}), true)
	testing.expect_value(t, reply_to_bool(Reply{kind = .Bulk_String, text = "1"}), true)
	testing.expect_value(t, reply_to_bool(Reply{kind = .Simple_String, text = "0"}), false)
	testing.expect_value(t, reply_to_bool(Reply{kind = .Bulk_String, text = "x"}), false)
	testing.expect_value(t, reply_to_bool(Reply{kind = .Null}), false)
}

@(test)
test_reply_to_f64 :: proc(t: ^testing.T) {
	testing.expect_value(t, reply_to_f64(Reply{kind = .Integer, integer = 7}), f64(7.0))
	testing.expect_value(t, reply_to_f64(Reply{kind = .Bulk_String, text = "3.14"}), f64(3.14))
	testing.expect_value(t, reply_to_f64(Reply{kind = .Simple_String, text = "-2.5"}), f64(-2.5))
	testing.expect_value(t, reply_to_f64(Reply{kind = .Bulk_String, text = "x"}), f64(0.0))
	testing.expect_value(t, reply_to_f64(Reply{kind = .Error, text = "ERR nope"}), f64(0.0))
	testing.expect_value(t, reply_to_f64(Reply{kind = .Null}), f64(0.0))
}

@(test)
test_get_missing_key_returns_null :: proc(t: ^testing.T) {
	ctx := connect_test_client(t)
	if ctx == nil {
		return
	}

	state := rand.create(t.seed)
	gen := rand.default_random_generator(&state)

	key := random_key("odis:test:get-missing:", gen)
	ctx.key = key

	reply, err := get(&ctx.client, key)
	defer destroy_reply(&reply)

	if !assert_ok_reply(t, reply, err, .Null) {
		return
	}
}

@(test)
test_set_get_del_roundtrip_random_values :: proc(t: ^testing.T) {
	ctx := connect_test_client(t)
	if ctx == nil {
		return
	}

	state := rand.create(t.seed)
	gen := rand.default_random_generator(&state)

	for _ in 0 ..< 50 {
		key := random_key("odis:test:roundtrip:", gen)
		value := random_string(1 + rand.int_max(128, gen), gen)

		cleanup_key(ctx, key)

		set_reply, set_err := set(&ctx.client, key, value)
		if !assert_ok_reply(t, set_reply, set_err, .Simple_String) {
			destroy_reply(&set_reply)
			delete(key)
			delete(value)
			return
		}
		testing.expect_value(t, set_reply.text, "OK")
		destroy_reply(&set_reply)

		get_reply, get_err := get(&ctx.client, key)
		if !assert_ok_reply(t, get_reply, get_err, .Bulk_String) {
			destroy_reply(&get_reply)
			cleanup_key(ctx, key)
			delete(key)
			delete(value)
			return
		}
		testing.expect_value(t, get_reply.text, value)
		destroy_reply(&get_reply)

		del_reply, del_err := del(&ctx.client, []string{key})
		if !assert_ok_reply(t, del_reply, del_err, .Integer) {
			destroy_reply(&del_reply)
			delete(key)
			delete(value)
			return
		}
		testing.expect_value(t, del_reply.integer, i64(1))
		destroy_reply(&del_reply)

		delete(key)
		delete(value)
	}
}

@(test)
test_set_ex_expires_key :: proc(t: ^testing.T) {
	ctx := connect_test_client(t)
	if ctx == nil {
		return
	}

	state := rand.create(t.seed + 1)
	gen := rand.default_random_generator(&state)

	key := random_key("odis:test:set-ex:", gen)
	value := random_string(24, gen)
	defer delete(key)
	defer delete(value)

	cleanup_key(ctx, key)

	set_reply, set_err := set_ex(&ctx.client, key, value, 1)
	defer destroy_reply(&set_reply)
	if !assert_ok_reply(t, set_reply, set_err, .Simple_String) {
		return
	}
	testing.expect_value(t, set_reply.text, "OK")

	get_reply_now, get_err_now := get(&ctx.client, key)
	defer destroy_reply(&get_reply_now)
	if !assert_ok_reply(t, get_reply_now, get_err_now, .Bulk_String) {
		return
	}
	testing.expect_value(t, get_reply_now.text, value)

	time.sleep(1500 * time.Millisecond)

	get_reply_later, get_err_later := get(&ctx.client, key)
	defer destroy_reply(&get_reply_later)
	if !assert_ok_reply(t, get_reply_later, get_err_later, .Null) {
		return
	}
}

randomized_client_roundtrip_leak_check :: proc(t: ^testing.T) {
	ctx := connect_test_client_no_cleanup(t)
	if ctx == nil {
		return
	}
	defer destroy_test_client_context(ctx)

	state := rand.create(t.seed + 0x9e3779b97f4a7c15)
	gen := rand.default_random_generator(&state)

	for _ in 0 ..< 20 {
		key := random_key("odis:test:leak-check:", gen)
		value := random_string(32 + rand.int_max(96, gen), gen)

		set_reply, set_err := set(&ctx.client, key, value)
		testing.expect_value(t, set_err, Error.None)
		destroy_reply(&set_reply)

		get_reply, get_err := get(&ctx.client, key)
		testing.expect_value(t, get_err, Error.None)
		testing.expect_value(t, get_reply.text, value)
		destroy_reply(&get_reply)

		del_reply, del_err := del(&ctx.client, []string{key})
		testing.expect_value(t, del_err, Error.None)
		destroy_reply(&del_reply)

		delete(key)
		delete(value)
	}
}

randomized_client_roundtrip_leak_verifier :: proc(t: ^testing.T, ta: ^mem.Tracking_Allocator) {
	testing.expect_value(t, len(ta.allocation_map), 0)
	testing.expect_value(t, len(ta.bad_free_array), 0)
}

@(test)
test_random_roundtrip_has_no_leaks :: proc(t: ^testing.T) {
	testing.expect_leaks(
		t,
		randomized_client_roundtrip_leak_check,
		randomized_client_roundtrip_leak_verifier,
	)
}

@(test)
test_set_ex_rejects_non_positive_seconds :: proc(t: ^testing.T) {
	ctx := connect_test_client(t)
	if ctx == nil {
		return
	}

	reply_zero, err_zero := set_ex(&ctx.client, "odis:test:set-ex-invalid", "v", 0)
	defer destroy_reply(&reply_zero)
	testing.expect_value(t, err_zero, Error.Invalid_Argument)

	reply_neg, err_neg := set_ex(&ctx.client, "odis:test:set-ex-invalid", "v", -1)
	defer destroy_reply(&reply_neg)
	testing.expect_value(t, err_neg, Error.Invalid_Argument)
}

@(test)
test_set_bool_roundtrip :: proc(t: ^testing.T) {
	ctx := connect_test_client(t)
	if ctx == nil {
		return
	}

	state := rand.create(t.seed + 2)
	gen := rand.default_random_generator(&state)

	key := random_key("odis:test:set-bool:", gen)
	ctx.key = key

	// true deve essere codificato come "1"
	set_reply_true, set_err_true := set_bool(&ctx.client, key, true)
	defer destroy_reply(&set_reply_true)
	if !assert_ok_reply(t, set_reply_true, set_err_true, .Simple_String) {
		return
	}

	get_reply_true, get_err_true := get(&ctx.client, key)
	defer destroy_reply(&get_reply_true)
	if !assert_ok_reply(t, get_reply_true, get_err_true, .Bulk_String) {
		return
	}
	testing.expect_value(t, get_reply_true.text, "1")

	// false deve essere codificato come "0"
	set_reply_false, set_err_false := set_bool(&ctx.client, key, false)
	defer destroy_reply(&set_reply_false)
	if !assert_ok_reply(t, set_reply_false, set_err_false, .Simple_String) {
		return
	}

	get_reply_false, get_err_false := get(&ctx.client, key)
	defer destroy_reply(&get_reply_false)
	if !assert_ok_reply(t, get_reply_false, get_err_false, .Bulk_String) {
		return
	}
	testing.expect_value(t, get_reply_false.text, "0")
}

@(test)
test_set_int_roundtrip :: proc(t: ^testing.T) {
	ctx := connect_test_client(t)
	if ctx == nil {
		return
	}

	state := rand.create(t.seed + 3)
	gen := rand.default_random_generator(&state)

	key := random_key("odis:test:set-int:", gen)
	ctx.key = key

	cases := [][2]string{{"0", "0"}, {"42", "42"}, {"-7", "-7"}}
	values := []int{0, 42, -7}

	for i in 0 ..< len(values) {
		set_reply, set_err := set_int(&ctx.client, key, values[i])
		if !assert_ok_reply(t, set_reply, set_err, .Simple_String) {
			destroy_reply(&set_reply)
			return
		}
		destroy_reply(&set_reply)

		get_reply, get_err := get(&ctx.client, key)
		if !assert_ok_reply(t, get_reply, get_err, .Bulk_String) {
			destroy_reply(&get_reply)
			return
		}
		testing.expect_value(t, get_reply.text, cases[i][1])
		destroy_reply(&get_reply)
	}
}

@(test)
test_set_f32_roundtrip :: proc(t: ^testing.T) {
	ctx := connect_test_client(t)
	if ctx == nil {
		return
	}

	state := rand.create(t.seed + 4)
	gen := rand.default_random_generator(&state)

	key := random_key("odis:test:set-f32:", gen)
	ctx.key = key

	values := []f32{0.0, 3.14159, -2.5, 1000.0}
	for v in values {
		set_reply, set_err := set_f32(&ctx.client, key, v)
		if !assert_ok_reply(t, set_reply, set_err, .Simple_String) {
			destroy_reply(&set_reply)
			return
		}
		destroy_reply(&set_reply)

		get_reply, get_err := get(&ctx.client, key)
		if !assert_ok_reply(t, get_reply, get_err, .Bulk_String) {
			destroy_reply(&get_reply)
			return
		}

		buf: [64]byte
		expected := fmt.bprintf(buf[:], "%.4f", v)
		testing.expect_value(t, get_reply.text, expected)
		destroy_reply(&get_reply)
	}
}

@(test)
test_set_f64_roundtrip :: proc(t: ^testing.T) {
	ctx := connect_test_client(t)
	if ctx == nil {
		return
	}

	state := rand.create(t.seed + 5)
	gen := rand.default_random_generator(&state)

	key := random_key("odis:test:set-f64:", gen)
	ctx.key = key

	values := []f64{0.0, 3.141592653589793, -2.5, 1000.0}
	for v in values {
		set_reply, set_err := set_f64(&ctx.client, key, v)
		if !assert_ok_reply(t, set_reply, set_err, .Simple_String) {
			destroy_reply(&set_reply)
			return
		}
		destroy_reply(&set_reply)

		get_reply, get_err := get(&ctx.client, key)
		if !assert_ok_reply(t, get_reply, get_err, .Bulk_String) {
			destroy_reply(&get_reply)
			return
		}

		buf: [64]byte
		expected := fmt.bprintf(buf[:], "%.4f", v)
		testing.expect_value(t, get_reply.text, expected)
		destroy_reply(&get_reply)
	}
}
