opdir		 = $(datadir)/vyatta-op/templates

bin_SCRIPTS	 = scripts/vyatta-show-queue
bin_SCRIPTS	 += scripts/vyatta-show-queueing.pl
bin_SCRIPTS	 += scripts/show-input-policy.pl

cpiop = find  . ! -regex '\(.*~\|.*\.bak\|.*\.swp\|.*\#.*\#\)' -print0 | \
	cpio -0pd

install-exec-hook:
	mkdir -p $(DESTDIR)$(opdir)
	cd templates; $(cpiop) $(DESTDIR)$(opdir)


