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
	client, err := redis.connect(redis.Config{
		address = "127.0.0.1:6379",
	})
	if err != .None {
		fmt.eprintln("connect error:", err)
		os.exit(1)
	}
	defer redis.close(&client)
	key := "odis:getdel:foo"

	set_reply, set_err := redis.set(&client, key, "42")
	expect(set_err == .None, "SET EX returned an error")
	expect(set_reply.kind == .Simple_String, "SET EX reply kind mismatch")
	expect(set_reply.text == "OK", "SET EX reply text mismatch")

	getd_reply, getd_err := redis.getdel(&client, key)
	expect(getd_err == .None, "GETDEL returned an error")
	expect(getd_reply.kind == .Bulk_String, "GETDEL reply kind mismatch")
	expect(getd_reply.text == "42", "GETDEL reply text mismatch")

	get_reply, get_err := redis.getdel(&client, key)
	expect(get_err == .None, "GETDEL returned an error")
	fmt.println(get_reply.kind)
	expect(get_reply.kind == .Null, "GET reply kind mismatch")

	fmt.println("getdel passed")
}
