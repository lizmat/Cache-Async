[![Actions Status](https://github.com/lizmat/Cache-Async/actions/workflows/linux.yml/badge.svg)](https://github.com/lizmat/Cache-Async/actions) [![Actions Status](https://github.com/lizmat/Cache-Async/actions/workflows/macos.yml/badge.svg)](https://github.com/lizmat/Cache-Async/actions) [![Actions Status](https://github.com/lizmat/Cache-Async/actions/workflows/windows.yml/badge.svg)](https://github.com/lizmat/Cache-Async/actions)

NAME
====

Cache::Async -- A Concurrent and Asynchronous Cache

SYNOPSIS
========

```raku
my $cache = Cache::Async.new(max-size => 1000, producer => sub ($k) { ... });
say await $cache.get('key234');
```

FEATURES
========

  * Producer function that gets passed in on construction and that gets called by cache on misses

  * Cache size and maximum entry age can be limited

  * Cache allows refreshing of entries even before they have expired

  * Calls producer async and returns promise to result, perfect for usage in an otherwise async or reactive system

  * Transparent support for producers that return promises themselves

  * Extra args can be passed through to producer easily

  * Jitter for refresh and expiry to smooth out producer calls over time

  * Locked internally so it can be used from multiple threads or a thread pool, but no lock help while calling the producer function.

  * Propagates exceptions from producer transparently

  * Get entry from cache only if present, without loading/refreshing.

  * Configurably, Nil values can be passed through without caching them

  * Monitoring of hit rate

Upcoming Features
-----------------

  * Optimizations of the async producer case

  * Object lifetimes can be restricted by producer function

BLOG
====

I also have a short article that cache users might find interesting [The Surprising Sanity of Using a Cache but Not Updating It](https://github.com/Raku/CCR/blob/main/Remaster/Robert%20Lemmen/The%20Surprising%20Sanity%20of%20Using%20a%20Cache%20but%20Not%20Updating%20It.md).

DESCRIPTION
===========

This module tries to implement a cache that can be used easily in otherwise async or reactive system. As such it only returns Promises to results which can then be composed with other promises, or acted on directly.

It tries to be a 'transparent' cache in the sense that it will return a cached item, or a freshly produced or retrieved one without the caller being aware of the distinction. To do this, the cache is constructed over a producer sub that gets called on cache misses.

Sometimes other data that is required by the producer function can be captured at creation time, but in other cases they need to be provided at request time, e.g. credentials. Arguments like these can be passed through `Cache::Async` transparently as extra args.

All caches should have a fixed size limit, and so does Cache::Async of course. In addition a maximum global object lifetime can be specified to avoid overly old object entries. For cache eviction a LRU mechanism is used.

If caches are used in production systems, it is often desirable to monitor their hit rates. Cache::Async supports this through a method that reports hits and misses, but it does not do the monitoring itself or automatically.

Constructor
===========

```raku
new(:&producer, Int :$max-size, Duration :$max-age, Duration :$refresh-after,
    Duration :$jitter, Bool :$cache-undefined = True)
```

Creates a new cache over the provided **&producer** sub, which must take a single string as the first argument, the key used to look up items in the cache with. It can take more arguments, see **get()** below.

The **$max-size** argument can be used to limit the number of items the cache will hold at any time, the default is 1024.

**$max-age** determines the maximum age an item can live in the cache before it is expired. By default items are not expired by age.

**$refresh-after** optionally sets a time after which an item will be refreshed by the cache in parallel with returning it. This can be used to reduce latency for frequently used entries. When set (to a value lower than **$max-age** of course), the cache will upon a hit on an entry that is older than this value immediately return the existing value, but also start an asyncronous re-fetch of the item as if it had experienced a cache miss. This can be used to make frequently used items always come from the cache, rather than incurring a cache hit with the corresponding fetch latency every now and then.

**$jitter** optionally sets a maximum jitter duration. When an item is refreshed and placed in the cache, the timestamp of the item is incremented by a random interval between 0 and this duration. This can be useful if your application loads many items after boot and wants to make sure that the refresh times spread out over time and do not stay clustered together. This value needs to be smaller than **$refresh-after** (and therefore **max-age**), the default is zero.

If **$cache-undefined** is set to False, then undefined return values from the producer function (as well as Promises that are undefined when kept of course) are not cached and will be retried the next time the coresponding key is queried.

The following example will create a simple cache with up to 100 items that live for up to 10 seconds. The values returned by the cache are promises that will hold the key specified when querying the cache enclosed in square brackets.

    $cache = Cache::Async.new(producer => sub ($k) { return "[$k]"; },
                              max-size => 100,
                              max-age => Duration.new(10));

Retrieval
=========

In order to get items from, or better through, the cache, the **get()** method is used:

```raku
$cache.get($key, +@args)
```

The first argument is the **$key** used to look up items in the cache, and is passed through to the producer function the cache uses. Any other arguments are also passed to the producer functions. The call returns a `Promise` to the value produced or found in the cache.

With the cache constructed above, the call below would yield "[woot]". The first time this is called the producer is called, afterwards the cached value is used (until expiry or eviction).

```raku
await $cache.get('woot')
```

Multiple threads can of course safely call into the cache in parallel.

The producer function can of course return a `Promise` itself! In this case `Cache::Async` will *not* return a promise containing another promise, but it will detect the case and simply return the promise from the producer directly.

Cache Content Management
========================

The following methods can be used to manage the contents of the cache. This can for example be used to warm the cache on startup with some values, or clear it in error cases.

```raku
$cache.put($key, $value);
$cache.remove($key);
$cache.clear;
```

As a special case, you can also query for contents of the cache, but without calling the producer function on a miss, and without touching any cache statistics. This is useful to check for entry existence in cache maintenance tasks, but also and primarily when doing operations that violate the LRU criteria. For example imagine a cache with limited size over a very large backing resource, but with normal operations that show strong LRU characteristics. A perfect case for a cache, and you can expect good cache hit rates. Now every now and then a maintenance task kicks in that traverses all resources. This could also benefit from the cache, but if it updates the cache it would basically replace the whole cache with the tail end of it's iteration, destroying the LRU properties of the cache and causing increased cache misses for some time afterwards, a bit like a cache that is empty. This method allows utilising entries in the cache if present, but not touching the cache otherwise. Returns Nil if no entry is found.

```raku
$cache.get-if-present($key);
```

Monitoring
==========

The behavior of the cache can be monitored, the call will return total numbers since the last time this method was called (or the cache got constructed):

```raku
my ($hits, $misses) = $cache.hits-misses;
```

Note that the number of hits + misses is of course the number of calls to **get()**, but that the number of calls to the producer function is not necessarily the same as the number of misses returned from this method. The reason for this is that two calls to the cache with the same key in rapid succession could both be misses, but only the first one will call the producer. The second call will simply get chained to the first producer call.

AUTHORS
=======

Robert Lemmen

Elizabeth Mattijsen

Source can be located at: https://github.com/lizmat/Cache-Async . Comments and Pull Requests are welcome.

If you like this module, or what I’m doing more generally, committing to a [small sponsorship](https://github.com/sponsors/lizmat/) would mean a great deal to me!

COPYRIGHT AND LICENSE
=====================

Copyright 2018-2020 Robert Lemmen

Copyright 2021, 2024, 2025 Elizabeth Mattijsen

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

