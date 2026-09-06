#include <errno.h>
#include <unistd.h>
int main(void) { char byte; ssize_t count; do { count=read(STDIN_FILENO,&byte,1); } while(count<0&&errno==EINTR); return count==1?125:126; }
