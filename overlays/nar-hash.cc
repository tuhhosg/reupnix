/**
 * This is an extract from the Nix sources allowing to do one thing only: Create a hash of a file in exactly the same way as »nix-store --optimise« does it.
 * Compile with: nix-shell -p openssl gcc --run 'g++ -std=c++17 -lcrypto -lssl -O3 nar-hash.cc -o nar-hash'
 * Then call with one absolute or relative path as first argument. The hash will be printed to stdout.
 *
 * Composed of code snippets from https://github.com/NixOS/nix/, which is released under the LGPL v2.1 (https://github.com/NixOS/nix/blob/master/COPYING).
 */


/// header things

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <linux/limits.h>
#include <memory>
#include <openssl/sha.h>
#include <unistd.h>
#include <sstream>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <vector>

typedef std::string Path;

const int hashSize = 32;
const size_t base32Len = (hashSize * 8 - 1) / 5 + 1;

struct Hash
{
    uint8_t hash[hashSize] = {};

    /* Create a zero-filled hash object. */
    Hash();

};

/* Compute the hash of the given path.  The hash is defined as
   (essentially) hashString(dumpPath(path)). */
typedef std::pair<Hash, uint64_t> HashResult;

struct Sink
{
    virtual ~Sink() { }
    virtual void operator () (std::string_view data) = 0;
    virtual bool good() { return true; }
};

struct BufferedSink : virtual Sink
{
    size_t bufSize, bufPos;
    std::unique_ptr<char[]> buffer;

    BufferedSink(size_t bufSize = 32 * 1024)
        : bufSize(bufSize), bufPos(0), buffer(nullptr) { }

    void operator () (std::string_view data) override;

    void flush();

    virtual void write(std::string_view data) = 0;
};

struct AbstractHashSink : virtual Sink
{
    virtual HashResult finish() = 0;
};

class HashSink : public BufferedSink, public AbstractHashSink
{
private:
    SHA256_CTX * ctx;
    uint64_t bytes;

public:
    HashSink();
    ~HashSink();
    void write(std::string_view data) override;
    HashResult finish() override;
};


/// implementation


Hash::Hash() {
    memset(hash, 0, hashSize);
}

void BufferedSink::operator () (std::string_view data)
{
    if (!buffer) buffer = decltype(buffer)(new char[bufSize]);

    while (!data.empty()) {
        /* Optimisation: bypass the buffer if the data exceeds the
           buffer size. */
        if (bufPos + data.size() >= bufSize) {
            flush();
            write(data);
            break;
        }
        /* Otherwise, copy the bytes to the buffer.  Flush the buffer
           when it's full. */
        size_t n = bufPos + data.size() > bufSize ? bufSize - bufPos : data.size();
        memcpy(buffer.get() + bufPos, data.data(), n);
        data.remove_prefix(n); bufPos += n;
        if (bufPos == bufSize) flush();
    }
}

void BufferedSink::flush()
{
    if (bufPos == 0) return;
    size_t n = bufPos;
    bufPos = 0; // don't trigger the assert() in ~BufferedSink()
    write({buffer.get(), n});
}

HashSink::HashSink() {
    ctx = new SHA256_CTX;
    bytes = 0;
    SHA256_Init(ctx);
}

HashSink::~HashSink()
{
    bufPos = 0;
    delete ctx;
}

void HashSink::write(std::string_view data)
{
    bytes += data.size();
    // std::cout << data;
    SHA256_Update(ctx, data.data(), data.size());
}

HashResult HashSink::finish()
{
    flush();
    Hash hash;
    SHA256_Final(hash.hash, ctx);
    return HashResult(hash, bytes);
}

inline Sink & operator << (Sink & sink, uint64_t n)
{
    unsigned char buf[8];
    buf[0] = n & 0xff;
    buf[1] = (n >> 8) & 0xff;
    buf[2] = (n >> 16) & 0xff;
    buf[3] = (n >> 24) & 0xff;
    buf[4] = (n >> 32) & 0xff;
    buf[5] = (n >> 40) & 0xff;
    buf[6] = (n >> 48) & 0xff;
    buf[7] = (unsigned char) (n >> 56) & 0xff;
    sink({(char *) buf, sizeof(buf)});
    return sink;
}

void writePadding(size_t len, Sink & sink)
{
    if (len % 8) {
        char zero[8];
        memset(zero, 0, sizeof(zero));
        sink({zero, 8 - (len % 8)});
    }
}

void writeString(std::string_view data, Sink & sink)
{
    sink << data.size();
    sink(data);
    writePadding(data.size(), sink);
}

Sink & operator << (Sink & sink, std::string_view s)
{
    writeString(s, sink);
    return sink;
}

const std::string base32Chars = "0123456789abcdfghijklmnpqrsvwxyz";

static std::string printHash32(const Hash & hash)
{
    std::string s;
    s.reserve(base32Len);

    for (int n = (int) base32Len - 1; n >= 0; n--) {
        unsigned int b = n * 5;
        unsigned int i = b / 8;
        unsigned int j = b % 8;
        unsigned char c =
            (hash.hash[i] >> j)
            | (i >= hashSize - 1 ? 0 : hash.hash[i + 1] << (8 - j));
        s.push_back(base32Chars[c & 0x1f]);
    }

    return s;
}

void readFull(int fd, char * buf, size_t count)
{
    while (count) {
        ssize_t res = read(fd, buf, count);
        if (res == -1) {
            if (errno == EINTR) continue;
            fprintf(stderr, "Error reading from file"); exit(1);
        }
        if (res == 0) { fprintf(stderr, "Unexpected end-of-file"); exit(1); }
        count -= res;
        buf += res;
    }
}

Path readLink(const Path & path)
{
    std::vector<char> buf;
    for (ssize_t bufSize = PATH_MAX/4; true; bufSize += bufSize/2) {
        buf.resize(bufSize);
        ssize_t rlSize = readlink(path.c_str(), buf.data(), bufSize);
        if (rlSize == -1)
            if (errno == EINVAL)
                { fprintf(stderr, "Error: '%s' is not a symlink", path.c_str()); exit(1); }
            else
                { fprintf(stderr, "Error: reading symbolic link '%s'", path.c_str()); exit(1); }
        else if (rlSize < bufSize)
            return std::string(buf.data(), rlSize);
    }
}

static void dumpContents(const Path & path, off_t size,
    Sink & sink)
{
    sink << "contents" << size;

    auto fd = open(path.c_str(), O_RDONLY | O_CLOEXEC); // let system close this
    if (!fd) { fprintf(stderr, "opening file '%s'", path.c_str()); exit(1); }

    std::vector<char> buf(65536);
    size_t left = size;

    while (left > 0) {
        auto n = std::min(left, buf.size());
        readFull(fd, buf.data(), n);
        left -= n;
        sink({buf.data(), n});
    }

    writePadding(size, sink);
}

struct stat lstat(const Path & path) {
    struct stat st; if (!lstat(path.c_str(), &st)) return st;
    fprintf(stderr, "Error getting status of '%s'", path.c_str()); exit(1);
}

void dump(const Path & path, Sink & sink)
{
    auto st = lstat(path.c_str());

    sink << "(";

    if (S_ISREG(st.st_mode)) {
        sink << "type" << "regular";
        if (st.st_mode & S_IXUSR)
            sink << "executable" << "";
        dumpContents(path, st.st_size, sink);
    }

    else if (S_ISLNK(st.st_mode))
        sink << "type" << "symlink" << "target" << readLink(path);

    else { fprintf(stderr, "Error: file '%s' has an unsupported type", path.c_str()); exit(1); }

    sink << ")";
}

const std::string narVersionMagic1 = "nix-archive-1";

HashResult hashPath(const Path & path) {
    HashSink sink;
    sink << narVersionMagic1;
    dump(path, sink);
    return sink.finish();
}

int main(int argc, char *argv[]) {
    Hash hash = hashPath(argv[1]).first;
    fprintf(stdout, "%s", printHash32(hash).c_str());
}
