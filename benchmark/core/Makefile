#TEST_DURATION=600
#TEST_HOSTS=5
#TEST_SERVICES=50
TEST_SITES=nagios3 nagios4 icinga nagios3_gearman nagios4_gearman icinga_gearman
TEST_COMMANDS=simple simple.sh simple.pl simple_epn.pl big.pl big_epn.pl

testall:
	for cmd in $(TEST_COMMANDS); do \
		TEST_COMMAND="$$cmd" TEST_SITES="$(TEST_SITES)" make test; \
	done

test:
	@echo "starting test..."
	./site_control.pl benchmark

build:
	cd plugins && make

create:
	./site_control.pl create

clean:
	./site_control.pl clean
