package main

import redis ".."
import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"

expect :: proc(ok: bool, message: string) {
	if ok {
		return
	}
	fmt.eprintln("verification failed:", message)
	os.exit(1)
}

main :: proc() {
	reply_arena: vmem.Arena
	if arena_err := vmem.arena_init_growing(&reply_arena); arena_err != nil {
		fmt.eprintln("arena init error:", arena_err)
		os.exit(1)
	}
	defer vmem.arena_destroy(&reply_arena)
	reply_allocator := vmem.arena_allocator(&reply_arena)

	client, err := redis.connect(redis.Config{address = "127.0.0.1:6379"})
	if err != .None {
		fmt.eprintln("connect error:", err)
		os.exit(1)
	}
	defer redis.close(&client)

	key := "odis:reuse-reply-allocator:example"

	mem.free_all(reply_allocator)
	set_reply, set_err := redis.set(&client, key, "42", reply_allocator)
	expect(set_err == .None, "SET returned an error")
	expect(set_reply.kind == .Simple_String, "SET reply kind mismatch")
	expect(set_reply.text == "OK", "SET reply text mismatch")

	mem.free_all(reply_allocator)
	get_reply, get_err := redis.get(&client, key, reply_allocator)
	expect(get_err == .None, "GET returned an error")
	expect(get_reply.kind == .Bulk_String, "GET reply kind mismatch")
	expect(get_reply.text == "42", "GET reply text mismatch")

	mem.free_all(reply_allocator)
	del_reply, del_err := redis.del(&client, []string{key}, reply_allocator)
	expect(del_err == .None, "DEL returned an error")
	expect(del_reply.kind == .Integer, "DEL reply kind mismatch")
	expect(del_reply.integer == 1, "DEL reply integer mismatch")

	fmt.println("reply allocator reused successfully")
}
