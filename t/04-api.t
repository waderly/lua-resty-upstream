# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (12);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    error_log logs/error.log debug;

    lua_shared_dict test_upstream 1m;

    init_by_lua '
        upstream_socket  = require("resty.upstream.socket")
        upstream_api = require("resty.upstream.api")

        upstream, configured = upstream_socket:new("test_upstream")
        test_api = upstream_api:new(upstream)

        test_api:createPool({id = "primary", timeout = 100})

        test_api:createPool({id = "secondary", timeout = 100, priority = 10})
    ';
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: Cannot add existing pool
--- http_config eval: $::HttpConfig
--- log_level: debug
--- config
    location = /a {
        content_by_lua '
            local ok,err = test_api:createPool({id = "primary"})
            if not ok then
                ngx.status = 200
            else
                ngx.status = 500
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /a
--- errorcode: 200

=== TEST 2: Cannot set unavailable load-balancing method
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local ok, err = test_api:setMethod("primary", "foobar")
            if not ok then
                ngx.status = 200
            else
                ngx.status = 500
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /a
--- error_code: 200

=== TEST 3: Cannot set non-numeric priority
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local ok, err = test_api:setPriority("primary", "foobar")
            if not ok then
                ngx.status = 200
            else
                ngx.status = 500
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /a
--- error_code: 200

=== TEST 4: Cannot create pool with bad values
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local ok, err = test_api:createPool({
                    id = "testpool",
                    priority = "abcd",
                    timeout = "foo",
                    method = "bar",
                    max_fails = "three",
                    fail_timeout = "sixty"
                })

            if not ok then
                ngx.status = 200
            else
                ngx.status = 500
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /a
--- error_code: 200

=== TEST 5: Cannot add host to non-existent pool
--- http_config eval: $::HttpConfig
--- config
    location = / {
        content_by_lua '
            local ok, err = test_api:addHost("foobar", { id="a", host = ngx.var.server_addr, port = ngx.var.server_port+1, weight = 10 })
            if not ok then
                ngx.status = 200
            else
                ngx.status = 500
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /
--- errorcode: 200

=== TEST 6: addHost works
--- http_config eval: $::HttpConfig
--- log_level: debug
--- config
    location = / {
        content_by_lua '
            test_api:addHost("primary", { id="a", host = ngx.var.server_addr, port = ngx.var.server_port, weight = 1 })

            local pools, err = upstream:getPools()
            if pools.primary.hosts.a == nil then
                ngx.status = 500
                ngx.say(err)
            end
        ';
    }
--- request
GET /
--- error_code: 200

=== TEST 7: Mixed specific and implied host IDs
--- http_config eval: $::HttpConfig
--- config
    location = / {
        content_by_lua '
            test_api:addHost("primary", { host = ngx.var.server_addr, port = ngx.var.server_port, weight = 1 })
            test_api:addHost("primary", { id="a", host = ngx.var.server_addr, port = ngx.var.server_port, weight = 1 })
            test_api:addHost("primary", { host = ngx.var.server_addr, port = ngx.var.server_port, weight = 1 })
            test_api:addHost("primary", { id="foo", host = ngx.var.server_addr, port = ngx.var.server_port, weight = 1 })

            local pools, err = upstream:getPools()
            local ids = {}
            for k,v in pairs(pools.primary.hosts) do
                table.insert(ids, tostring(k))
            end
            table.sort(ids)
            for k,v in ipairs(ids) do
                ngx.say(v)
            end
        ';
    }
--- request
GET /
--- response_body
1
2
a
foo

=== TEST 8: hostDown marks host down and sets manual flag
--- http_config eval: $::HttpConfig
--- config
    location = / {
        content_by_lua '
            test_api:addHost("primary", { id="a", host = ngx.var.server_addr, port = ngx.var.server_port, weight = 1 })
            test_api:hostDown("primary", "a")

            local pools, err = upstream:getPools()
            if pools.primary.hosts.a.up ~= false or pools.primary.hosts.a.manual == nil then
                ngx.status = 500
            end
        ';
    }
--- request
GET /
--- error_code: 200

=== TEST 9: hostUp marks host up and clears manual flag
--- http_config eval: $::HttpConfig
--- log_level: debug
--- config
    location = / {
        content_by_lua '
            test_api:addHost("primary", { id="a", host = ngx.var.server_addr, port = ngx.var.server_port, weight = 1 })
            test_api:hostDown("primary", "a")
            test_api:hostUp("primary", "a")

            local pools, err = upstream:getPools()
            if pools.primary.hosts.a.up ~= true or pools.primary.hosts.a.manual ~= nil then
                ngx.status = 500
                ngx.say(err)
            end
        ';
    }
--- request
GET /
--- error_code: 200

=== TEST 10: removeHost deletes host
--- http_config eval: $::HttpConfig
--- log_level: debug
--- config
    location = / {
        content_by_lua '
            test_api:addHost("primary", { id="a", host = ngx.var.server_addr, port = ngx.var.server_port, weight = 1 })
            test_api:removeHost("primary", "a")

            local pools, err = upstream:getPools()
            if pools.primary.hosts.a ~= nil then
                ngx.status = 500
                ngx.say(err)
            end
        ';
    }
--- request
GET /
--- error_code: 200

=== TEST 11: api:getPools passes through to upstream
--- http_config eval: $::HttpConfig
--- log_level: debug
--- config
    location = / {
        content_by_lua '
            test_api:addHost("primary", { id="a", host = ngx.var.server_addr, port = ngx.var.server_port, weight = 1 })

            local pools, err = test_api:getPools()
            if pools.primary.hosts.a == nil then
                ngx.status = 500
                ngx.say(err)
            end
        ';
    }
--- request
GET /
--- error_code: 200
