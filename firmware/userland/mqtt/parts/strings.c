/* Small string and number helpers; the daemon uses no libc.
 * Part of doorview-mqtt.c, which #includes the parts in order: the daemon stays one translation unit and builds to
 * the same binary as before the split. A part does not compile on its own. */

static int str_len(const char *text)
{
    int length = 0;

    while (text[length])
        length++;
    return length;
}

static int str_eq(const char *a, const char *b)
{
    while (*a && *a == *b) {
        a++;
        b++;
    }
    return *a == *b;
}

static void str_copy(char *to, int capacity, const char *from)
{
    int index = 0;

    while (from[index] && index < capacity - 1) {
        to[index] = from[index];
        index++;
    }
    to[index] = 0;
}

/* Copies a configuration value only if it fits completely; a silently truncated path or password is worse than an error. */
static int store(char *to, int capacity, const char *from)
{
    if (str_len(from) >= capacity)
        return 0;
    str_copy(to, capacity, from);
    return 1;
}

static const char *find_text(const char *text, int length, const char *needle)
{
    int needle_length = str_len(needle);
    int index;

    for (index = 0; index + needle_length <= length; index++) {
        int match = 1;
        int offset;

        for (offset = 0; offset < needle_length; offset++) {
            if (text[index + offset] != needle[offset]) {
                match = 0;
                break;
            }
        }
        if (match)
            return text + index;
    }
    return 0;
}

/* Bounded output buffer. */
struct out {
    char *data;
    int length;
    int capacity;
    int overflow;
};

static void put_char(struct out *o, char value)
{
    if (o->length + 1 > o->capacity) {
        o->overflow = 1;
        return;
    }
    o->data[o->length++] = value;
}

static void put_text(struct out *o, const char *text)
{
    while (*text)
        put_char(o, *text++);
}

static void put_decimal(struct out *o, int value)
{
    /* No division: the freestanding ARM build has no runtime divide helper. */
    static const unsigned int powers[] = { 1000000000u, 100000000u, 10000000u, 1000000u, 100000u,
                                           10000u,      1000u,      100u,      10u,      1u };
    unsigned int magnitude = value < 0 ? 0u - (unsigned int)value : (unsigned int)value;
    int started = 0;
    int index;

    if (value < 0)
        put_char(o, '-');
    for (index = 0; index < 10; index++) {
        unsigned int digit = 0;

        while (magnitude >= powers[index]) {
            magnitude -= powers[index];
            digit++;
        }
        if (digit || started || index == 9) {
            put_char(o, (char)('0' + digit));
            started = 1;
        }
    }
}

static void logmsg(const char *text)
{
    char line[96];
    struct out o = { line, 0, (int)sizeof(line) - 1, 0 };

    put_text(&o, "doorview-mqtt: ");
    put_text(&o, text);
    put_char(&o, '\n');
    sys_write(1, line, o.length);
}
