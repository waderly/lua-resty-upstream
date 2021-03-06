# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * 9;

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

        test_api:create_pool({id = "primary", timeout = 100})

        test_api:create_pool({id = "secondary", timeout = 100, priority = 10})
        ';
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: Connecting to a single host
--- http_config eval: $::HttpConfig
--- log_level: debug
--- config
    location = / {
        content_by_lua '
            test_api:add_host("primary", { id="a", host = ngx.var.server_addr, port = ngx.var.server_port, weight = 1 })

            local ok, err = upstream:connect()
            if ok then
                ngx.say("OK")
            else
                ngx.say(err)
            end
        ';
    }
--- request
GET /
--- no_error_log
[error]
[warn]
--- response_body
OK

=== TEST 2: Mark single host down after 3 fails
--- http_config eval: $::HttpConfig
--- config
    location = / {
        content_by_lua '
            test_api:add_host("primary", { id="a", host = ngx.var.server_addr, port = ngx.var.server_port+1, weight = 10 })

            -- Simulate 3 connection attempts
            for i=1,3 do
                upstream:connect()
                upstream:post_process()
            end

            pools = upstream:get_pools()

            if pools.primary.hosts.a.up then
                ngx.status = 500
                ngx.say("FAIL")
            else
                ngx.status = 200
                ngx.say("OK")
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /
--- response_body
OK

=== TEST 3: Mark round_robin host down after 3 fails
--- http_config eval: $::HttpConfig
--- config
    location = / {
        content_by_lua '
            test_api:add_host("primary", { id="a", host = ngx.var.server_addr, port = ngx.var.server_port+1, weight = 9999 })
            test_api:add_host("primary", { id="b", host = ngx.var.server_addr, port = ngx.var.server_port+1, weight = 1 })

            -- Simulate 3 connection attempts
            for i=1,3 do
                upstream:connect()
                upstream:post_process()
            end

            pools = upstream:get_pools()

            if pools.primary.hosts.a.up then
                ngx.say("FAIL")
                ngx.status = 500
            else
                ngx.say("OK")
                ngx.status = 200
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /
--- response_body
OK

=== TEST 4: Manually offline hosts are not reset
--- http_config eval: $::HttpConfig
--- config
    location = / {
        content_by_lua '
            test_api:add_host("primary", { id="a", host = ngx.var.server_addr, port = ngx.var.server_port, weight = 1 })
            test_api:down_host("primary", "a")
            upstream:_background_func()

            local pools, err = upstream:get_pools()

            if pools.primary.hosts.a.up ~= false or pools.primary.hosts.a.manual == nil then
                ngx.status = 500
            end
        ';
    }
--- request
GET /
--- error_code: 200
