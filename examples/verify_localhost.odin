package main

import "core:fmt"
import "core:mem"
import "core:os"
import redis ".."

expect :: proc(ok: bool, message: string) {
	if ok {
		return
	}
	fmt.eprintln("verification failed:", message)
	os.exit(1)
}

main :: proc() {
	base_allocator := context.allocator
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, base_allocator)
	tracker.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	defer mem.tracking_allocator_destroy(&tracker)
	context.allocator = mem.tracking_allocator(&tracker)
	defer context.allocator = base_allocator

	client, err := redis.connect(redis.Config{
		address = "127.0.0.1:6379",
	})
	if err != .None {
		fmt.eprintln("connect error:", err)
		os.exit(1)
	}

	ping_reply, ping_err := redis.ping(&client, "odin")
	expect(ping_err == .None, "PING returned an error")
	expect(ping_reply.kind == .Bulk_String || ping_reply.kind == .Simple_String, "PING reply kind mismatch")
	expect(ping_reply.text == "odin", "PING reply payload mismatch")

	key := "odis:verify:example"

	set_reply, set_err := redis.set(&client, key, "42")
	expect(set_err == .None, "SET returned an error")
	expect(set_reply.kind == .Simple_String, "SET reply kind mismatch")
	expect(set_reply.text == "OK", "SET reply text mismatch")

	get_reply, get_err := redis.get(&client, key)
	expect(get_err == .None, "GET returned an error")
	expect(get_reply.kind == .Bulk_String, "GET reply kind mismatch")
	expect(get_reply.text == "42", "GET reply text mismatch")
	expect(redis.reply_to_int(get_reply) == 42, "GET reply text mismatch")
	expect(redis.reply_to_f64(get_reply) == f64(42.), "reply_to_f64  error")
	expect(!redis.reply_to_bool(get_reply), "reply_to_bool error")

	del_reply, del_err := redis.del(&client, []string{key})
	expect(del_err == .None, "DEL returned an error")
	expect(del_reply.kind == .Integer, "DEL reply kind mismatch")
	expect(del_reply.integer == 1, "DEL reply integer mismatch")

	redis.destroy_reply(&del_reply)
	redis.destroy_reply(&get_reply)
	redis.destroy_reply(&set_reply)
	redis.destroy_reply(&ping_reply)
	redis.close(&client)

	if len(tracker.allocation_map) != 0 || len(tracker.bad_free_array) != 0 {
		for _, leak in tracker.allocation_map {
			fmt.eprintf("leak: %v leaked %v bytes\n", leak.location, leak.size)
		}
		for bad_free in tracker.bad_free_array {
			fmt.eprintf("bad free: %v for %p\n", bad_free.location, bad_free.memory)
		}
		fmt.eprintln("memory verification failed")
		os.exit(1)
	}

	fmt.println("redis verification passed")
}
