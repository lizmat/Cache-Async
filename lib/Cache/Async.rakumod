unit class Cache::Async;

=begin pod

=head1 NAME

Cache::Async -- A Concurrent and Asynchronous Cache

=head1 SYNOPSIS

=begin code :lang<raku>

my $cache = Cache::Async.new(max-size => 1000, producer => sub ($k) { ... });
say await $cache.get('key234');

=end code

=head1 FEATURES

=item Producer function that gets passed in on construction and that gets called by cache on misses

=item Cache size and maximum entry age can be limited

=item Cache allows refreshing of entries even before they have expired

=item Calls producer async and returns promise to result, perfect for usage in an otherwise async or reactive system

=item Transparent support for producers that return promises themselves

=item Extra args can be passed through to producer easily

=item Jitter for refresh and expiry to smooth out producer calls over time

=item Locked internally so it can be used from multiple threads or a thread pool, but no lock help while calling the producer function.

=item Propagates exceptions from producer transparently

=item Get entry from cache only if present, without loading/refreshing.

=item Configurably, Nil values can be passed through without caching them

=item Monitoring of hit rate

=head2 Upcoming Features

=item Optimizations of the async producer case

=item Object lifetimes can be restricted by producer function

=head1 BLOG

I also have a short article that cache users might find interesting L<The Surprising Sanity of Using a Cache but Not Updating It|https://github.com/Raku/CCR/blob/main/Remaster/Robert%20Lemmen/The%20Surprising%20Sanity%20of%20Using%20a%20Cache%20but%20Not%20Updating%20It.md>.

=head1 DESCRIPTION

This module tries to implement a cache that can be used easily in otherwise
async or reactive system. As such it only returns Promises to results which
can then be composed with other promises, or acted on directly.

It tries to be a 'transparent' cache in the sense that it will return a
cached item, or a freshly produced or retrieved one without the caller being
aware of the distinction. To do this, the cache is constructed over a producer
sub that gets called on cache misses.

Sometimes other data that is required by the producer function can be captured
at creation time, but in other cases they need to be provided at request time,
e.g. credentials. Arguments like these can be passed through C<Cache::Async>
transparently as extra args.

All caches should have a fixed size limit, and so does Cache::Async of course.
In addition a maximum global object lifetime can be specified to avoid overly
old object entries. For cache eviction a LRU mechanism is used.

If caches are used in production systems, it is often desirable to monitor their
hit rates. Cache::Async supports this through a method that reports hits and
misses, but it does not do the monitoring itself or automatically.

=head1 Constructor

=begin code :lang<raku>

new(:&producer, Int :$max-size, Duration :$max-age, Duration :$refresh-after,
    Duration :$jitter, Bool :$cache-undefined = True)

=end code

Creates a new cache over the provided B<&producer> sub, which must take
a single string as the first argument, the key used to look up items in
the cache with. It can take more arguments, see B<get()> below.

The B<$max-size> argument can be used to limit the number of items the
cache will hold at any time, the default is 1024.

B<$max-age> determines the maximum age an item can live in the cache
before it is expired. By default items are not expired by age.

B<$refresh-after> optionally sets a time after which an item will be
refreshed by the cache in parallel with returning it. This can be used
to reduce latency for frequently used entries. When set (to a value
lower than B<$max-age> of course), the cache will upon a hit on an
entry that is older than this value immediately return the existing
value, but also start an asyncronous re-fetch of the item as if it
had experienced a cache miss. This can be used to make frequently used
items always come from the cache, rather than incurring a cache hit
with the corresponding fetch latency every now and then.

B<$jitter> optionally sets a maximum jitter duration. When an item is
refreshed and placed in the cache, the timestamp of the item is
incremented by a random interval between 0 and this duration. This can
be useful if your application loads many items after boot and wants to
make sure that the refresh times spread out over time and do not stay
clustered together. This value needs to be smaller than B<$refresh-after>
(and therefore B<max-age>), the default is zero.

If B<$cache-undefined> is set to False, then undefined return values from
the producer function (as well as Promises that are undefined when kept
of course) are not cached and will be retried the next time the coresponding
key is queried.

The following example will create a simple cache with up to 100 items that
live for up to 10 seconds. The values returned by the cache are promises
that will hold the key specified when querying the cache enclosed in square
brackets.

=begin code

$cache = Cache::Async.new(producer => sub ($k) { return "[$k]"; },
                          max-size => 100,
                          max-age => Duration.new(10));

=end code

=end pod

my class Entry {
    has Str $.key;
    has $.value is rw;
    has $.timestamp is rw; # XXX would like this to be Instant but then it can't be nullable
    has Bool $.is-refreshing is rw;
    has Entry $.older is rw;
    has Entry $.younger is rw;
    has Promise $.promise is rw;
}

has &.producer;
has Int $.max-size = 1024;
has $.max-age; # XXX would like these three to be Duration, but then they are not nullable
has Bool $.cache-undefined = True;
has $.refresh-after;
has $.jitter;

has Entry %!entries;
has Entry $!youngest;
has Entry $!oldest;
has Lock $!lock = Lock.new;

has atomicint $!hits   = 0;
has atomicint $!misses = 0;

method TWEAK() {
    my $min = $!max-age;
    if $!max-age.defined && $!refresh-after.defined {
        if $!max-age <= $!refresh-after {
            die "max-age cannot be less than refresh-after";
        }
        $min = $!refresh-after;
    }
    if $min.defined && $!jitter.defined {
        if $!jitter >= $min {
            die "jitter cannot be larger or equals to refresh-after/max-age";
        }
    }
    if !$min.defined && $!jitter.defined {
        die "jitter set, but neither max-age nor refresh-after set";
    }
}

method !unlink($entry) {
    if $!youngest === $entry {
        $!youngest = $entry.older;
    }
    if $!oldest === $entry {
        $!oldest = $entry.younger;
    }
    if $entry.older.defined {
        $entry.older.younger = $entry.younger;
        $entry.older = Nil;
    }
    if $entry.younger.defined {
        $entry.younger.older = $entry.older;
        $entry.younger = Nil;
    }
}

method !link($entry) {
    $!youngest.younger = $entry if $!youngest.defined;
    $entry.older = $!youngest;
    $!youngest   = $entry;
    $!oldest     = $entry unless $!oldest.defined;
}

method !expire-by-count() {
    while %!entries.elems > $!max-size {
        my $evicted = $!oldest;
        my $key = $evicted.key;
        %!entries{$evicted.key}:delete;
        self!unlink($evicted);
    }
}

method !expire-by-age($now) {
    while $!oldest.defined && $!oldest.timestamp < ($now - $!max-age) {
        # XXX duplication from above
        my $evicted = $!oldest;
        my $key = $evicted.key;
        %!entries{$evicted.key}:delete;
        self!unlink($evicted);
    }
}

=begin pod

=head1 Retrieval

In order to get items from, or better through, the cache, the B<get()>
method is used:

=begin code :lang<raku>

$cache.get($key, +@args)

=end code

The first argument is the B<$key> used to look up items in the cache, and
is passed through to the producer function the cache uses. Any other
arguments are also passed to the producer functions. The call returns a
C<Promise> to the value produced or found in the cache.

With the cache constructed above, the call below would yield "[woot]". The
first time this is called the producer is called, afterwards the cached
value is used (until expiry or eviction).

=begin code :lang<raku>

await $cache.get('woot')

=end code

Multiple threads can of course safely call into the cache in parallel.

The producer function can of course return a C<Promise> itself! In this
case C<Cache::Async> will I<not> return a promise containing another promise,
but it will detect the case and simply return the promise from the producer
directly.

=end pod

method get($key, +@args --> Promise:D) {
    my $entry;
    my $now = Nil;
    $!lock.protect({
        if $!max-age.defined {
            $now = now;
            self!expire-by-age($now);
        }
        elsif $!refresh-after.defined {
            $now = now;
        }
        $entry = %!entries{$key};
        if !$entry.defined {
            atomic-inc-fetch($!misses);
            my $new-ts = $now;
            $new-ts += Duration.new($!jitter.Numeric.rand) if $!jitter.defined;

            $entry = Entry.new(key => $key.Str, timestamp => $new-ts);
            %!entries{$key} = $entry;
            self!link($entry);
            $entry.promise = Promise.new;
            my $producer-promise = Promise.start({
                my $prod-result = &.producer.($key, |@args);
                CATCH {
                    default: $entry.promise.break($_);
                }
                CONTROL {
                    default: $entry.promise.break($_);
                }
                $!lock.protect({
                    if $prod-result.isa(Promise) {
                        $prod-result.then(-> $value {
                            $!lock.protect({
                                if $value.status ~~ Kept {
                                    if $value.result.defined
                                      || $.cache-undefined {
                                        $entry.value = $value.result;
                                        $entry.promise.keep($value.result);
                                        $entry.promise = Nil;
                                    }
                                    else {
                                        $entry.promise.keep($value.result);
                                        %!entries{$entry.key}:delete;
                                        self!unlink($entry);
                                    }
                                }
                                else {
                                    $entry.promise.break($value.cause);
                                    $entry.promise = Nil;
                                }
                            });
                        });
                    }
                    else {
                        if $prod-result.defined || $.cache-undefined {
                            $entry.value = $prod-result;
                            $entry.promise.keep($prod-result);
                            $entry.promise = Nil;
                        }
                        else {
                            $entry.promise.keep($prod-result);
                            %!entries{$entry.key}:delete;
                            self!unlink($entry);
                        }
                    }
                });
            });
            self!expire-by-count();
            $entry.promise
        }
        else {
            # XXX hm, should this not move it to the front?
            if $entry.promise.defined {
                atomic-inc-fetch($!misses);
                return $entry.promise;
            }
            else {
                atomic-inc-fetch($!hits);
                my $ret = Promise.new;
                $ret.keep($entry.value);
                if defined $!refresh-after {
                    if $now > $entry.timestamp + $!refresh-after {
                        unless $entry.is-refreshing {
                            $entry.is-refreshing = True;
                            my $refresh-promise = Promise.start({
                                my $prod-result = &.producer.($key, |@args);
                                CATCH {
                                    # ignore, this is just a refresh attempt
                                    # anyway
                                }
                                $!lock.protect({
                                    if $prod-result.isa(Promise) {
                                        $prod-result.then(-> $value {
                                            $!lock.protect({
                                                if $value.status ~~ Kept {
                                                    $entry.value = $value.result;
                                                    $entry.is-refreshing = False;
                                                    my $new-ts = $now;
                                                    $new-ts += Duration.new($!jitter.Numeric.rand)
                                                      if $!jitter.defined;
                                                    $entry.timestamp = $new-ts;
                                                }
                                                else {
                                                    # error, ignore as we are
                                                    # just refreshing
                                                }
                                            });
                                        });
                                    }
                                    else {
                                        $entry.value = $prod-result;
                                        $entry.is-refreshing = False;
                                        my $new-ts = $now;
                                        $new-ts += Duration.new($!jitter.Numeric.rand)
                                          if $!jitter.defined;
                                        $entry.timestamp = $new-ts;
                                    }
                                });
                            });
                        }
                    }
                }
                return $ret;
            }
        }
    });
}

=begin pod

=head1 Cache Content Management

The following methods can be used to manage the contents of the cache. This
can for example be used to warm the cache on startup with some values, or
clear it in error cases.

=begin code :lang<raku>

$cache.put($key, $value);
$cache.remove($key);
$cache.clear;

=end code

=end pod

method put($key, $value) {
    $!lock.protect({
        my $entry = %!entries{$key};
        unless $entry.defined {
            $entry = Entry.new(key => $key.Str, value => $value);
            %!entries{$key} = $entry;
        }
        $entry.value = $value;
        self!expire-by-count;
    });
}

method remove($key) {
    $!lock.protect({
        my $removed = %!entries{$key};
        self!unlink($removed) if $removed.defined;
        %!entries{$key}:delete;
    });
}

method clear() {
    $!lock.protect({
        %!entries  = ();
        $!youngest = Nil;
        $!oldest  = Nil;
    });
}

# XXX this ought to be after the get() to make the pod less confusing
# also: does this method make sense? isn't it better to call the producer
# but not update the cache?

=begin pod

As a special case, you can also query for contents of the cache, but without
calling the producer function on a miss, and without touching any cache
statistics. This is useful to check for entry existence in cache maintenance
tasks, but also and primarily when doing operations that violate the LRU
criteria. For example imagine a cache with limited size over a very large
backing resource, but with normal operations that show strong LRU
characteristics. A perfect case for a cache, and you can expect good cache
hit rates. Now every now and then a maintenance task kicks in that traverses
all resources. This could also benefit from the cache, but if it updates the
cache it would basically replace the whole cache with the tail end of it's
iteration, destroying the LRU properties of the cache and causing increased
cache misses for some time afterwards, a bit like a cache that is empty.
This method allows utilising entries in the cache if present, but not
touching the cache otherwise. Returns Nil if no entry is found.

=begin code :lang<raku>

$cache.get-if-present($key);

=end code

=end pod

method get-if-present($key) {
    $!lock.protect({
        # we still need to do this in order to ensure we do not return stale
        # entries.
        if $!max-age.defined {
            my $now = now;
            self!expire-by-age($now);
        }
        my $entry = %!entries{$key};
        if $entry.defined {
            return $entry.value unless $entry.promise.defined;
        }
    });
    Nil
}

=begin pod

=head1 Monitoring

The behavior of the cache can be monitored, the call will return total
numbers since the last time this method was called (or the cache got
constructed):

=begin code :lang<raku>

my ($hits, $misses) = $cache.hits-misses;

=end code

Note that the number of hits + misses is of course the number of calls to
B<get()>, but that the number of calls to the producer function is not
necessarily the same as the number of misses returned from this method. The
reason for this is that two calls to the cache with the same key in rapid
succession could both be misses, but only the first one will call the
producer. The second call will simply get chained to the first producer
call.

=end pod

method hits-misses() {
    my $current-hits = atomic-fetch($!hits);
    my $current-misses = atomic-fetch($!misses);
    atomic-fetch-sub($!hits, $current-hits);
    atomic-fetch-sub($!misses, $current-misses);
    ($current-hits, $current-misses);
}

=begin pod

=head1 AUTHORS

Robert Lemmen

Elizabeth Mattijsen

Source can be located at: https://github.com/lizmat/Cache-Async . Comments and
Pull Requests are welcome.

If you like this module, or what I’m doing more generally, committing to a
L<small sponsorship|https://github.com/sponsors/lizmat/>  would mean a great
deal to me!

=head1 COPYRIGHT AND LICENSE

Copyright 2018-2020 Robert Lemmen

Copyright 2021, 2024, 2025 Elizabeth Mattijsen

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

=end pod

# vim: expandtab shiftwidth=4
