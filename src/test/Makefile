all: test

test: test_zones test_ipams test_dns test_subnets test_vnets_blackbox

test_zones: run_test_zones.pl
	./run_test_zones.pl

test_ipams: run_test_ipams.pl
	./run_test_ipams.pl

test_dns: run_test_dns.pl
	./run_test_dns.pl

test_subnets: run_test_subnets.pl
	./run_test_subnets.pl

test_vnets_blackbox: run_test_vnets_blackbox.pl
	./run_test_vnets_blackbox.pl

clean:
