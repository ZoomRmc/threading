#
#
#                                    Nim's Runtime Library
#        (c) Copyright 2021 Andreas Prell, Mamy André-Ratsimbazafy & Nim Contributors
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#
# This Channel implementation is a shared memory, fixed-size, concurrent queue using
# a circular buffer for data. Based on channels implementation[1]_ by
# Mamy André-Ratsimbazafy (@mratsim), which is a C to Nim translation of the
# original[2]_ by Andreas Prell (@aprell)
#
# .. [1] https://github.com/mratsim/weave/blob/5696d94e6358711e840f8c0b7c684fcc5cbd4472/unused/channels/channels_legacy.nim
# .. [2] https://github.com/aprell/tasking-2.0/blob/master/src/channel_shm/channel.c

## This module only works with `--gc:arc` or `--gc:orc`.
##
## .. warning:: This module is experimental and its interface may change.
##
## This module implements multi-producer multi-consumer channels - a concurrency
## primitive with a high-level interface intended for communication and
## synchronization between threads. It allows sending and receiving typed, isolated
## data, enabling safe and efficient concurrency.
##
## The `Chan` type represents a generic fixed-size channel object that internally manages
## the underlying resources and synchronization. It has to be initialized using
## the `newChan` proc. Sending and receiving operations are provided by the
## blocking `send` and `recv` procs, and non-blocking `trySend` and `tryRecv`
## procs. Send operations add messages to the channel, receiving operations 
## remove them.
## 
## See also:
## * [std/isolation](https://nim-lang.org/docs/isolation.html)
##
## The following is a simple example of two different ways to use channels:
## blocking and non-blocking.

runnableExamples("--threads:on --gc:orc"):
  import std/os

  # In this example a channel is declared at module scope.
  # Channels are generic, and they include support for passing objects between
  # threads.
  # Note that isolated data passed through channels is moved around.
  var chan = newChan[string]()

  block example_blocking:
    # This proc will be run in another thread.
    proc basicWorker() =
      chan.send("Hello World!")

    # Launch the worker.
    var worker: Thread[void]
    createThread(worker, basicWorker)

    # Block until the message arrives, then print it out.
    var dest = ""
    dest = chan.recv()
    assert dest == "Hello World!"

    # Wait for the thread to exit before moving on to the next example.
    worker.joinThread()

  block example_non_blocking:
    # This is another proc to run in a background thread. This proc takes a while
    # to send the message since it first sleeps for some time.
    proc slowWorker(delay: Natural) =
      # `delay` is a period in milliseconds
      sleep(delay)
      chan.send("Another message")

    # Launch the worker with a delay set to 2 seconds (2000 ms).
    var worker: Thread[Natural]
    createThread(worker, slowWorker, 2000)

    # This time, use a non-blocking approach with tryRecv.
    # Since the main thread is not blocked, it could be used to perform other
    # useful work while it waits for data to arrive on the channel.
    var messages: seq[string]
    while true:
      var msg = ""
      if chan.tryRecv(msg):
        messages.add msg # "Another message"
        break
      messages.add "Pretend I'm doing useful work..."
      # For this example, sleep in order not to flood the sequence with too many
      # "pretend" messages.
      sleep(400)

    # Wait for the second thread to exit before cleaning up the channel.
    worker.joinThread()

    # Thread exits right after receiving the message
    assert messages[^1] == "Another message"
    # At least one non-successful attempt to receive the message had to occur.
    assert messages.len >= 2

when not defined(gcArc) and not defined(gcOrc) and not defined(nimdoc):
  {.error: "This channel implementation requires --gc:arc or --gc:orc".}

import std/[locks, atomics, isolation]
import system/ansi_c

# Channel
# ------------------------------------------------------------------------------

type
  ChannelRaw = ptr ChannelObj
  ChannelObj = object
    lock: Lock
    spaceAvailableCV, dataAvailableCV: Cond
    slots: int    ## Number of item slots in the buffer
    head: int     ## Write/enqueue/send index
    tail: int     ## Read/dequeue/receive index
    buffer: ptr UncheckedArray[byte]
    atomicCounter: Atomic[int]

# ------------------------------------------------------------------------------

func numItems(chan: ChannelRaw): int {.inline.} =
  result = chan.head - chan.tail
  if result < 0:
    inc(result, 2 * chan.slots)

  assert result <= chan.slots

template isFull(chan: ChannelRaw): bool =
  abs(chan.head - chan.tail) == chan.slots

template isEmpty(chan: ChannelRaw): bool =
  chan.head == chan.tail

# Channels memory ops
# ------------------------------------------------------------------------------

proc allocChannel(size, n: int): ChannelRaw =
  result = cast[ChannelRaw](c_malloc(csize_t sizeof(ChannelObj)))

  # To buffer n items, we allocate for n
  result.buffer = cast[ptr UncheckedArray[byte]](c_malloc(csize_t n*size))

  initLock(result.lock)
  initCond(result.spaceAvailableCV)
  initCond(result.dataAvailableCV)

  result.slots = n
  result.head = 0
  result.tail = 0
  result.atomicCounter.store(0, moRelaxed)


proc freeChannel(chan: ChannelRaw) =
  if chan.isNil:
    return

  if not chan.buffer.isNil:
    c_free(chan.buffer)

  deinitLock(chan.lock)
  deinitCond(chan.spaceAvailableCV)
  deinitCond(chan.dataAvailableCV)

  c_free(chan)

# MPMC Channels (Multi-Producer Multi-Consumer)
# ------------------------------------------------------------------------------

proc channelSend(chan: ChannelRaw, data: pointer, size: int, blocking: static bool): bool =
  assert not chan.isNil
  assert not data.isNil

  when not blocking:
    if chan.isFull(): return false

  acquire(chan.lock)

  # check for when another thread was faster to fill
  when blocking:
    while chan.isFull():
      wait(chan.spaceAvailableCV, chan.lock)
  else:
    if chan.isFull():
      release(chan.lock)
      return false

  assert not chan.isFull()

  let writeIdx = if chan.head < chan.slots:
      chan.head
    else:
      chan.head - chan.slots

  copyMem(chan.buffer[writeIdx * size].addr, data, size)

  inc(chan.head)
  if chan.head == 2 * chan.slots:
    chan.head = 0

  signal(chan.dataAvailableCV)
  release(chan.lock)
  result = true

proc channelReceive(chan: ChannelRaw, data: pointer, size: int, blocking: static bool): bool =
  assert not chan.isNil
  assert not data.isNil

  when not blocking:
    if chan.isEmpty(): return false

  acquire(chan.lock)

  # check for when another thread was faster to empty
  when blocking:
    while chan.isEmpty():
      wait(chan.dataAvailableCV, chan.lock)
  else:
    if chan.isEmpty():
      release(chan.lock)
      return false

  assert not chan.isEmpty()

  let readIdx = if chan.tail < chan.slots:
      chan.tail
    else:
      chan.tail - chan.slots

  copyMem(data, chan.buffer[readIdx * size].addr, size)

  inc(chan.tail)
  if chan.tail == 2 * chan.slots:
    chan.tail = 0

  signal(chan.spaceAvailableCV)
  release(chan.lock)
  result = true

# Public API
# ------------------------------------------------------------------------------

type
  Chan*[T] = object ## Typed channel
    d: ChannelRaw

when defined(nimAllowNonVarDestructor):
  proc `=destroy`*[T](c: Chan[T]) =
    if c.d != nil:
      if load(c.d.atomicCounter, moAcquire) == 0:
        if c.d.buffer != nil:
          freeChannel(c.d)
      else:
        atomicDec(c.d.atomicCounter)
else:
  proc `=destroy`*[T](c: var Chan[T]) =
    if c.d != nil:
      if load(c.d.atomicCounter, moAcquire) == 0:
        if c.d.buffer != nil:
          freeChannel(c.d)
      else:
        atomicDec(c.d.atomicCounter)

proc `=copy`*[T](dest: var Chan[T], src: Chan[T]) =
  ## Shares `Channel` by reference counting.
  if src.d != nil:
    atomicInc(src.d.atomicCounter)

  if dest.d != nil:
    `=destroy`(dest)
  dest.d = src.d

proc trySend*[T](c: Chan[T], src: sink Isolated[T]): bool {.inline.} =
  ## Tries to send a message `src` to the channel `c`.
  ##
  ## The memory of `src` is moved, not copied. 
  ## Doesn't block waiting for space in the channel to become available.
  ## Instead returns after an attempt to send a message was made.
  ## 
  ## .. warning:: Blocking is still possible if another thread uses the blocking
  ##    version of `send`/`recv` and waits for the data/space to appear in the
  ##    channel, thus holding the internal lock to channel's buffer.
  ##
  ## Returns `false` if the message was not sent because the number of pending
  ## messages in the channel exceeded its capacity.
  var data = src.extract
  result = channelSend(c.d, data.unsafeAddr, sizeof(T), false)
  if result:
    wasMoved(data)

template trySend*[T](c: Chan[T], src: T): bool =
  ## Helper template for `trySend <#trySend,Chan[T],sinkIsolated[T]>`_.
  trySend(c, isolate(src))

proc tryRecv*[T](c: Chan[T], dst: var T): bool {.inline.} =
  ## Tries to receive an message from the channel `c` and fill `dst` with its value.
  ## 
  ## Doesn't block waiting for messages in the channel to become available.
  ## Instead returns after an attempt to receive a message was made.
  ## 
  ## .. warning:: Blocking is still possible if another thread uses the blocking
  ##    version of `send`/`recv` and waits for the data/space to appear in the
  ##    channel, thus holding the internal lock to channel's buffer.
  ## 
  ## Returns `false` and does not change `dist` if no message was received.
  channelReceive(c.d, dst.addr, sizeof(T), false)

proc send*[T](c: Chan[T], src: sink Isolated[T]) {.inline.} =
  ## Sends message `src` to the channel `c`. 
  ## This blocks the sending thread until `src` was successfully sent.
  ## 
  ## The memory of `src` is moved, not copied. 
  ## 
  ## If the channel is already full with messages this will block the thread until
  ## messages from the channel are removed.
  var data = src.extract
  when defined(gcOrc) and defined(nimSafeOrcSend):
    GC_runOrc()
  discard channelSend(c.d, data.unsafeAddr, sizeof(T), true)
  wasMoved(data)

template send*[T](c: Chan[T]; src: T) =
  ## Helper template for `send`.
  send(c, isolate(src))

proc recv*[T](c: Chan[T], dst: var T) {.inline.} =
  ## Receives a message from the channel `c` and fill `dst` with its value. 
  ## 
  ## This blocks the receiving thread until a message was successfully received.
  ## 
  ## If the channel does not contain any messages this will block the thread until
  ## a message get sent to the channel.
  discard channelReceive(c.d, dst.addr, sizeof(T), true)

proc recv*[T](c: Chan[T]): T {.inline.} =
  ## Receives a message from the channel. 
  ## A version of `recv`_ that returns the message.
  discard channelReceive(c.d, result.addr, sizeof(result), true)

proc recvIso*[T](c: Chan[T]): Isolated[T] {.inline.} =
  ## Receives a message from the channel.
  ## A version of `recv`_ that returns the message and isolates it.
  var dst: T
  discard channelReceive(c.d, dst.addr, sizeof(T), true)
  result = isolate(dst)

func peek*[T](c: Chan[T]): int {.inline.} =
  ## Returns an estimation of the current number of messages held by the channel.
  numItems(c.d)

proc newChan*[T](elements: Positive = 30): Chan[T] =
  ## An initialization procedure, necessary for acquiring resources and
  ## initializing internal state of the channel. 
  ## 
  ## `elements` is the capacity of the channel and thus how many messages it can hold 
  ## before it refuses to accept any further messages.
  assert elements >= 1, "Elements must be positive!"
  result = Chan[T](d: allocChannel(sizeof(T), elements))
