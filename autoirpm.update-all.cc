#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <rpmlib.h>
#include <string>
#include <set>
#include <fstream>


typedef set<string>::difference_type diff_type;

set<string> *read_set(const char *file) {
  ifstream input(file);
  if (input) {
    set<string> *myset = new set<string>;
    istream_iterator<string,diff_type> input_set(input),eos;
    copy(input_set, eos, inserter(*myset, myset->begin()));
    return myset;
  }
  return 0;
}

int main(int argc, char **argv) {
  if (argc <= 3) {
    cerr << "usage: " << argv[0] << " <allow progs file> <deny progs file> <hdlist> [<hdlist> ...]\n";
    exit(1);
  }

  set<string> *allow = read_set(argv[1]);
  set<string> *deny  = read_set(argv[2]);

  for (int i = 3; i < argc; i++) {
    Header header;
    FD_t fd = strcmp(argv[i], "-") == 0 ? fdDup(STDIN_FILENO) : fdOpen(argv[i], O_RDONLY, 0);
    if (fdFileno(fd) < 0) {
      fprintf(stderr, "%s: cannot open file %s\n", argv[0], argv[i]);
      exit(1);
    }

    while ((header=headerRead(fd, HEADER_MAGIC_YES))) {
      int_32 type, count;
      unsigned short *p;
      char **f, *name, *s;
      int printed = 0;

      headerGetEntry(header, RPMTAG_NAME, &type, (void **) &name, &count);
      headerGetEntry(header, RPMTAG_FILEMODES, &type, (void **) &p, &count);
      headerGetEntry(header, RPMTAG_FILENAMES, &type, (void **) &f, &count);
      for (; count--; *p++, *f++)
	if ((*p & 040111) == 0111 && 
	    (s = strrchr(*f, '/')) && 
	    s - 3 >= *f && 
	    strncmp(s - 3, "bin", 3) == 0 &&
	    (!allow || allow->count(s + 1)) &&
	    (!deny || !deny->count(s + 1))) {

	  if (!printed) {
	    printed = 1;
	    cout << name;
	  }
	  cout << " " << *f;
	}
      if (printed) cout << "\n";
    }
    fdClose(fd);
  }
  return 0;
}
