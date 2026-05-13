from std.builtin.coroutine import AnyCoroutine, _coro_destroy_fn, _coro_resume_fn, _suspend_async

@always_inline
def yield_to_main():
    @always_inline
    @parameter
    def on_suspend(current: AnyCoroutine):
        # Called just before suspension.
        # You could store `current` here in a real scheduler.
        pass
    _suspend_async[on_suspend]()

@fieldwise_init
struct CompletionContext(TrivialRegisterPassable):
    # Same layout idea as the builtin coroutine context:
    #     callback + payload
    #
    # The payload is a pointer to our `done` flag.
    comptime callback_fn_type = (def(UnsafePointer[mut=True, Bool, MutExternalOrigin]) thin -> None)
    var callback: Self.callback_fn_type
    var done: UnsafePointer[mut=True, Bool, MutExternalOrigin]

def mark_done(done: UnsafePointer[mut=True, Bool, MutExternalOrigin]):
    done[] = True

@always_inline
def pippo():
    print("pippo prima")
    yield_to_main()
    print("pippo dopo")

async def demo():
    print("coro: start")
    yield_to_main()

    print("coro: resumed once")
    yield_to_main()

    pippo()

    print("coro: finishing")
    # When this function returns, the coroutine runtime calls
    # CompletionContext.callback(CompletionContext.done).

def main():
    var done = False

    # Calling async function creates a Coroutine, but does not run it yet.
    var c = demo()

    # Install our completion callback context.
    #
    # Do NOT call c._set_noop_callback() here, because we want completion
    # to call mark_done().
    c._get_ctx[CompletionContext]()[] = CompletionContext(mark_done, UnsafePointer(to=done).unsafe_origin_cast[MutExternalOrigin]())

    # Take ownership of the raw coroutine handle.
    var h = c^._take_handle()

    while not done:
        print("main: resume coroutine")

        _coro_resume_fn(h)

        if done:
            print("main: coroutine completed")
        else:
            print("main: coroutine yielded")

    # You own the raw handle, so destroy it once it is complete.
    _coro_destroy_fn(h)
