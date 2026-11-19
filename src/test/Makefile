all: test

test: test_zones test_static_routes test_ct_zones test_fabric_host_vrf test_ipams test_dns test_subnets test_vnets_blackbox test_running_config test_api_index

test_zones: run_test_zones.pl
	./run_test_zones.pl

test_static_routes: run_test_static_routes.pl
	./run_test_static_routes.pl

test_fabric_host_vrf: run_test_fabric_host_vrf.pl
	./run_test_fabric_host_vrf.pl

test_ct_zones: run_test_ct_zones.pl
	./run_test_ct_zones.pl

test_ipams: run_test_ipams.pl
	./run_test_ipams.pl

test_dns: run_test_dns.pl
	./run_test_dns.pl

test_subnets: run_test_subnets.pl
	./run_test_subnets.pl

test_vnets_blackbox: run_test_vnets_blackbox.pl
	./run_test_vnets_blackbox.pl

test_running_config: run_test_running_config.pl
	./run_test_running_config.pl

test_api_index: run_test_api_index.pl
	./run_test_api_index.pl

clean:
