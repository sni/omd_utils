#TEST_DURATION=600
#TEST_HOSTS=5
#TEST_SERVICES=50
TEST_SITES=nagios3 naemon icinga1 icinga2 nagios3_gearman naemon_gearman
TEST_COMMANDS=simple simple.sh simple.pl simple_epn.pl big.pl big_epn.pl
RESULTS=/var/tmp/coreresults

all: build create test

missing:
	for cmd in $(TEST_COMMANDS); do \
		for site in $(TEST_SITES); do \
			echo $(RESULTS)/$${site}_$${cmd}.csv; \
			if ! test -s $(RESULTS)/$${site}_$${cmd}.csv; then \
				make TEST_COMMANDS="$${cmd}" TEST_SITES="$${site}" testall; \
			else \
				echo "already exists"; \
			fi; \
		done; \
	done

testall:
	for cmd in $(TEST_COMMANDS); do \
		TEST_COMMAND="$$cmd" TEST_SITES="$(TEST_SITES)" make test; \
	done

test:
	@echo "starting test..."
	TEST_RESULTS=$(RESULTS) ./site_control.pl benchmark

build:
	cd plugins && make

create:
	./site_control.pl create

clean:
	./site_control.pl clean
