// The fetcher's closed set of blocked targets (SET-172). Nothing outside these lists is blocked: in particular
// NAT64, 6to4 and IPv4-compatible IPv6 forms and single-label hostnames are allowed by decision.

// A hostname equal to one of these, or ending in `.` plus one of them, is blocked.
const BLOCKED_HOST_SUFFIXES = ['localhost', 'local', 'internal', 'home.arpa'];

// [network, prefix length] in the IPv4 address space.
const BLOCKED_IPV4: readonly (readonly [string, number])[] = [
  ['0.0.0.0', 8],
  ['10.0.0.0', 8],
  ['100.64.0.0', 10],
  ['127.0.0.0', 8],
  ['169.254.0.0', 16],
  ['172.16.0.0', 12],
  ['192.168.0.0', 16],
  ['198.18.0.0', 15],
  ['224.0.0.0', 4],
  ['240.0.0.0', 4]
];

const IPV4 = /^(?:0|[1-9]\d{0,2})(?:\.(?:0|[1-9]\d{0,2})){3}$/;

/** Whether a hostname (as `URL#hostname` gives it, lowercase, any trailing dots ignored) is a blocked name. */
export function isBlockedHostname(hostname: string): boolean {
  const name = hostname.toLowerCase().replace(/\.+$/, '');
  return BLOCKED_HOST_SUFFIXES.some((suffix) => name === suffix || name.endsWith(`.${suffix}`));
}

/** Whether `value` is an IPv4 address in dotted-decimal form or an IPv6 address, with or without brackets. */
export function isIpAddress(value: string): boolean {
  return parseIpv4(value) !== undefined || parseIpv6(unbracket(value)) !== undefined;
}

/**
 * Whether an IP address is in a blocked range. A value that is not a valid address is blocked too, so a
 * malformed `resolveHost` result never passes.
 */
export function isBlockedAddress(address: string): boolean {
  const ipv4 = parseIpv4(address);
  if (ipv4 !== undefined) return isBlockedIpv4(ipv4);
  const ipv6 = parseIpv6(unbracket(address));
  if (ipv6 === undefined) return true;
  // ::ffff:0:0/96 maps an IPv4 address; it is blocked when that address is.
  if (ipv6.slice(0, 5).every((group) => group === 0) && ipv6[5] === 0xffff) return isBlockedIpv4(ipv6[6] * 0x10000 + ipv6[7]);
  if (ipv6.slice(0, 7).every((group) => group === 0)) return ipv6[7] <= 1; // :: and ::1
  if ((ipv6[0] & 0xfe00) === 0xfc00) return true; // fc00::/7, unique local
  if ((ipv6[0] & 0xffc0) === 0xfe80) return true; // fe80::/10, link local
  return false;
}

function isBlockedIpv4(address: number): boolean {
  return BLOCKED_IPV4.some(([network, bits]) => (address >>> (32 - bits)) === (parseIpv4(network)! >>> (32 - bits)));
}

function unbracket(value: string): string {
  return value.startsWith('[') && value.endsWith(']') ? value.slice(1, -1) : value;
}

/** A dotted-decimal IPv4 address as an unsigned 32-bit number. Leading zeros are rejected, as octal is ambiguous. */
function parseIpv4(value: string): number | undefined {
  if (!IPV4.test(value)) return undefined;
  const octets = value.split('.').map(Number);
  if (octets.some((octet) => octet > 255)) return undefined;
  return ((octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]) >>> 0;
}

/** An IPv6 address as eight 16-bit groups. Accepts `::` compression, a dotted IPv4 tail and a `%zone` suffix. */
function parseIpv6(value: string): number[] | undefined {
  const address = value.replace(/%[^%]+$/, '');
  const halves = address.split('::');
  if (halves.length > 2) return undefined;
  const parse = (part: string): number[] | undefined => {
    if (part === '') return [];
    const groups: number[] = [];
    const pieces = part.split(':');
    for (const [index, piece] of pieces.entries()) {
      if (index === pieces.length - 1 && piece.includes('.')) {
        const ipv4 = parseIpv4(piece);
        if (ipv4 === undefined) return undefined;
        groups.push(ipv4 >>> 16, ipv4 & 0xffff);
      } else if (/^[0-9a-f]{1,4}$/i.test(piece)) {
        groups.push(Number.parseInt(piece, 16));
      } else {
        return undefined;
      }
    }
    return groups;
  };
  const head = parse(halves[0]);
  const tail = halves.length === 2 ? parse(halves[1]) : [];
  if (!head || !tail) return undefined;
  if (halves.length === 1) return head.length === 8 ? head : undefined;
  const missing = 8 - head.length - tail.length;
  return missing >= 1 ? [...head, ...Array<number>(missing).fill(0), ...tail] : undefined;
}
