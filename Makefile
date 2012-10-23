PACKAGE  = elevation-profile
VERSION  = 0.9.1

INSTALL = install
INSTALL_DATA = $(INSTALL) -m 644
INSTALL_PROGRAM = $(INSTALL)

# Common prefix for installation directories.
# NOTE: This directory must exist when you start the install.
prefix = /usr/local
#prefix = /usr

exec_prefix = $(prefix)
bindir = $(exec_prefix)/bin
libdir = $(prefix)/lib
datarootdir = $(prefix)/share
datadir = $(datarootdir)
sysconfdir = $(prefix)/etc

#sysconfdir = /etc

# todo: doesn't use prefix (and default load-path doesn't include a
# /usr/local directory) / maybe use --pkglibdir?
SCMDIR=`gauche-config --sitelibdir`

SCMFILES=dem-gdal.scm elpro-client.scm elpro.scm elprows.scm		\
format-json.scm geod.scm google-elevation.scm runtime-compile.scm	\
svg-plot.scm

# not really needed
SCMFILES+=google-elevation-client.scm

DATAFILES=gmted2010_mn30@480.tif gmted2010_mn30@480.tif.aux.xml gmted2010_mn30@480.tif.ovr

all:

installdirs:
	$(INSTALL) -d $(DESTDIR)/$(SCMDIR)/
	$(INSTALL) -d $(DESTDIR)/$(datadir)/$(PACKAGE)
	$(INSTALL) -d $(DESTDIR)/$(bindir)
	$(INSTALL) -d $(DESTDIR)/$(sysconfdir)
	$(INSTALL) -d $(DESTDIR)/$(libdir)/cgi-bin

install: installdirs
	$(INSTALL_DATA) $(SCMFILES) $(DESTDIR)$(SCMDIR)/
	$(INSTALL_DATA) $(DATAFILES) $(DESTDIR)$(datadir)/$(PACKAGE)
	$(INSTALL_PROGRAM) elpro-bin $(DESTDIR)$(bindir)/elpro
	# todo: really overwrite existing config?
	$(INSTALL_DATA) elpro.conf $(DESTDIR)$(sysconfdir)/elpro
	$(INSTALL_PROGRAM) elpro.fcgi $(DESTDIR)$(libdir)/cgi-bin/

# todo: should make uninstall remove config file?!
uninstall:
	for i in $(SCMFILES); do rm -v $(DESTDIR)$(SCMDIR)/$$i; done
	for i in $(DATAFILES); do rm -v $(DESTDIR)$(datadir)/$(PACKAGE)/$$i; done
	-rmdir $(DESTDIR)$(datadir)/$(PACKAGE)
	rm -v $(DESTDIR)$(bindir)/elpro
	rm -v  $(DESTDIR)/$(libdir)/cgi-bin/elpro.fcgi

dist:
	mkdir $(PACKAGE)-$(VERSION) && \
		cp -vr Makefile README INSTALL COPYING elpro-bin elpro.conf \
			test-dem-gdal.scm \
			elpro.fcgi \
			$(DATAFILES) $(SCMFILES) \
			$(PACKAGE)-$(VERSION) \
		&& tar czvf $(PACKAGE)-$(VERSION).tar.gz $(PACKAGE)-$(VERSION) \
		&& rm -rf $(PACKAGE)-$(VERSION)

check:
	./test-dem-gdal.scm

clean:
	-rm -vf lores.tif N48E00* all.vrt*