#include <assert.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
int db_socket_option_matches(int, int, int, int);
int main(void) {
    int fd=socket(AF_INET, SOCK_DGRAM, 0);
    assert(fd >= 0);
    int ttl=65;
    assert(setsockopt(fd,IPPROTO_IP,IP_TTL,&ttl,sizeof(ttl))==0);
    int owned=dup(fd);
    assert(db_socket_option_matches(owned,IPPROTO_IP,IP_TTL,65));
    assert(!db_socket_option_matches(owned,IPPROTO_IP,IP_TTL,64));
    close(owned);
    assert(db_socket_option_matches(fd,IPPROTO_IP,IP_TTL,65));
    close(fd);
    assert(!db_socket_option_matches(fd,IPPROTO_IP,IP_TTL,65));
    int fd6=socket(AF_INET6,SOCK_DGRAM,0);
    assert(fd6 >= 0);
    assert(setsockopt(fd6,IPPROTO_IPV6,IPV6_UNICAST_HOPS,&ttl,sizeof(ttl))==0);
    assert(db_socket_option_matches(fd6,IPPROTO_IPV6,IPV6_UNICAST_HOPS,65));
    close(fd6);
    return 0;
}
