part of '../web_apis.dart';

/// `URL` and `URLSearchParams`, following the WHATWG URL parser.
/// Deviation: IDNA is approximated by NFC + lowercase + Punycode, without the
/// full UTS #46 mapping tables.
const String _jsUrl = r'''
(function (host, internal, natives) {
  'use strict';
  const g = globalThis;
  const { define, customInspect, cloneHooks, NOT_CLONED, DOMException, illegal } = internal;

  const SPECIAL_PORTS = { __proto__: null, ftp: 21, file: null, http: 80, https: 443, ws: 80, wss: 443 };
  const isSpecial = (scheme) => scheme in SPECIAL_PORTS;

  const FRAGMENT_SET = new Set([0x20, 0x22, 0x3c, 0x3e, 0x60]);
  const QUERY_SET = new Set([0x20, 0x22, 0x23, 0x3c, 0x3e]);
  const SPECIAL_QUERY_SET = new Set([...QUERY_SET, 0x27]);
  const PATH_SET = new Set([...QUERY_SET, 0x3f, 0x60, 0x7b, 0x7d]);
  const USERINFO_SET = new Set([...PATH_SET, 0x2f, 0x3a, 0x3b, 0x3d, 0x40, 0x5b, 0x5c, 0x5d, 0x5e, 0x7c]);
  const EMPTY_SET = new Set();

  const FORBIDDEN_HOST = /[\u0000\t\n\r #/:<>?@[\\\]^|]/;
  const FORBIDDEN_DOMAIN = /[\u0000-\u001f\u007f\t\n\r #/:<>?@[\\\]^|%]/;
  const ASCII_ALPHA = /[A-Za-z]/;
  const ASCII_ONLY = /^[\u0000-\u007f]*$/;
  const SCHEME_CHAR = /[A-Za-z0-9+\-.]/;
  const DIGITS = /^[0-9]+$/;
  const HEX = /^[0-9a-fA-F]+$/;
  const OCTAL = /^[0-7]+$/;
  const TAB_OR_NEWLINE = /[\t\n\r]/g;
  const TRIM_C0_OR_SPACE = /^[\u0000- ]+|[\u0000- ]+$/g;

  function percentEncodeCodePoint(char) {
    const bytes = natives.utf8Encode(char);
    let out = '';
    for (let i = 0; i < bytes.length; i++) {
      out += '%' + bytes[i].toString(16).toUpperCase().padStart(2, '0');
    }
    return out;
  }
  function encodeSet(text, set) {
    let out = '';
    for (const char of text) {
      const cp = char.codePointAt(0);
      out += cp <= 0x1f || cp > 0x7e || set.has(cp) ? percentEncodeCodePoint(char) : char;
    }
    return out;
  }
  function percentDecodeBytes(text) {
    const bytes = natives.utf8Encode(text);
    const out = new Uint8Array(bytes.length);
    let length = 0;
    for (let i = 0; i < bytes.length; i++) {
      if (bytes[i] !== 0x25 || i + 2 >= bytes.length ||
        !HEX.test(String.fromCharCode(bytes[i + 1], bytes[i + 2]))) {
        out[length++] = bytes[i];
      } else {
        out[length++] = parseInt(String.fromCharCode(bytes[i + 1], bytes[i + 2]), 16);
        i += 2;
      }
    }
    return out.subarray(0, length);
  }
  const percentDecode = (text) => natives.utf8Decode(percentDecodeBytes(text), false);

  // Punycode (RFC 3492) encoding of one label.
  function punycodeEncode(label) {
    const base = 36;
    const tmin = 1;
    const tmax = 26;
    const skew = 38;
    const damp = 700;
    const codePoints = Array.from(label, (c) => c.codePointAt(0));
    const basic = codePoints.filter((cp) => cp < 0x80);
    let out = basic.map((cp) => String.fromCharCode(cp)).join('');
    let handled = basic.length;
    const basicLength = basic.length;
    const total = codePoints.length;
    if (handled === total) return out;
    if (handled > 0) out += '-';
    let n = 128;
    let delta = 0;
    let bias = 72;
    const adapt = (d, numPoints, firstTime) => {
      d = firstTime ? Math.floor(d / damp) : Math.floor(d / 2);
      d += Math.floor(d / numPoints);
      let k = 0;
      while (d > Math.floor(((base - tmin) * tmax) / 2)) {
        d = Math.floor(d / (base - tmin));
        k += base;
      }
      return k + Math.floor(((base - tmin + 1) * d) / (d + skew));
    };
    const digitChar = (digit) => String.fromCharCode(digit + 22 + (digit < 26 ? 75 : 0));
    while (handled < total) {
      let m = Infinity;
      for (const cp of codePoints) if (cp >= n && cp < m) m = cp;
      delta += (m - n) * (handled + 1);
      n = m;
      for (const cp of codePoints) {
        if (cp < n) delta++;
        if (cp !== n) continue;
        let q = delta;
        for (let k = base; ; k += base) {
          const t = k <= bias ? tmin : k >= bias + tmax ? tmax : k - bias;
          if (q < t) break;
          out += digitChar(t + ((q - t) % (base - t)));
          q = Math.floor((q - t) / (base - t));
        }
        out += digitChar(q);
        bias = adapt(delta, handled + 1, handled === basicLength);
        delta = 0;
        handled++;
      }
      delta++;
      n++;
    }
    return 'xn--' + out;
  }
  function domainToASCII(domain) {
    const labels = domain.normalize('NFC').toLowerCase().split('.');
    const out = [];
    for (const label of labels) {
      out.push(ASCII_ONLY.test(label) ? label : punycodeEncode(label));
    }
    return out.join('.');
  }

  function parseIPv4Number(input) {
    if (input === '') return null;
    let radix = 10;
    let text = input;
    if (text.length >= 2 && (text.startsWith('0x') || text.startsWith('0X'))) {
      text = text.slice(2);
      radix = 16;
    } else if (text.length >= 2 && text.startsWith('0')) {
      text = text.slice(1);
      radix = 8;
    }
    if (text === '') return 0;
    const pattern = radix === 10 ? DIGITS : radix === 16 ? HEX : OCTAL;
    if (!pattern.test(text)) return null;
    return parseInt(text, radix);
  }
  function endsInNumber(input) {
    const parts = input.split('.');
    if (parts.length > 1 && parts[parts.length - 1] === '') parts.pop();
    const last = parts[parts.length - 1];
    if (last === undefined) return false;
    if (DIGITS.test(last)) return true;
    return parseIPv4Number(last) !== null;
  }
  function parseIPv4(input) {
    const parts = input.split('.');
    if (parts.length > 1 && parts[parts.length - 1] === '') parts.pop();
    if (parts.length > 4) return null;
    const numbers = [];
    for (const part of parts) {
      const value = parseIPv4Number(part);
      if (value === null) return null;
      numbers.push(value);
    }
    for (let i = 0; i < numbers.length - 1; i++) if (numbers[i] > 255) return null;
    if (numbers[numbers.length - 1] >= Math.pow(256, 5 - numbers.length)) return null;
    let address = numbers.pop();
    let counter = 0;
    for (const value of numbers) {
      address += value * Math.pow(256, 3 - counter);
      counter++;
    }
    return address;
  }
  function serializeIPv4(address) {
    let out = '';
    let value = address;
    for (let i = 1; i <= 4; i++) {
      out = String(value % 256) + out;
      if (i !== 4) out = '.' + out;
      value = Math.floor(value / 256);
    }
    return out;
  }
  function parseIPv6(input) {
    const address = [0, 0, 0, 0, 0, 0, 0, 0];
    let pieceIndex = 0;
    let compress = null;
    const chars = Array.from(input);
    let pointer = 0;
    const c = () => chars[pointer];
    if (c() === ':') {
      if (chars[pointer + 1] !== ':') return null;
      pointer += 2;
      pieceIndex++;
      compress = pieceIndex;
    }
    while (pointer < chars.length) {
      if (pieceIndex === 8) return null;
      if (c() === ':') {
        if (compress !== null) return null;
        pointer++;
        pieceIndex++;
        compress = pieceIndex;
        continue;
      }
      let value = 0;
      let length = 0;
      while (length < 4 && c() !== undefined && HEX.test(c())) {
        value = value * 16 + parseInt(c(), 16);
        pointer++;
        length++;
      }
      if (c() === '.') {
        if (length === 0) return null;
        pointer -= length;
        if (pieceIndex > 6) return null;
        let numbersSeen = 0;
        while (c() !== undefined) {
          let ipv4Piece = null;
          if (numbersSeen > 0) {
            if (c() === '.' && numbersSeen < 4) pointer++;
            else return null;
          }
          if (c() === undefined || !DIGITS.test(c())) return null;
          while (c() !== undefined && DIGITS.test(c())) {
            const number = parseInt(c(), 10);
            if (ipv4Piece === null) ipv4Piece = number;
            else if (ipv4Piece === 0) return null;
            else ipv4Piece = ipv4Piece * 10 + number;
            if (ipv4Piece > 255) return null;
            pointer++;
          }
          address[pieceIndex] = address[pieceIndex] * 256 + ipv4Piece;
          numbersSeen++;
          if (numbersSeen === 2 || numbersSeen === 4) pieceIndex++;
        }
        if (numbersSeen !== 4) return null;
        break;
      }
      if (c() === ':') {
        pointer++;
        if (c() === undefined) return null;
      } else if (c() !== undefined) {
        return null;
      }
      address[pieceIndex] = value;
      pieceIndex++;
    }
    if (compress !== null) {
      let swaps = pieceIndex - compress;
      pieceIndex = 7;
      while (pieceIndex !== 0 && swaps > 0) {
        const temp = address[compress + swaps - 1];
        address[compress + swaps - 1] = address[pieceIndex];
        address[pieceIndex] = temp;
        pieceIndex--;
        swaps--;
      }
    } else if (pieceIndex !== 8) {
      return null;
    }
    return address;
  }
  function serializeIPv6(address) {
    let out = '';
    let compress = null;
    let longest = 1;
    let current = null;
    let currentLength = 0;
    for (let i = 0; i < 8; i++) {
      if (address[i] === 0) {
        if (current === null) current = i;
        currentLength++;
        if (currentLength > longest) {
          longest = currentLength;
          compress = current;
        }
      } else {
        current = null;
        currentLength = 0;
      }
    }
    let ignore0 = false;
    for (let index = 0; index < 8; index++) {
      if (ignore0 && address[index] === 0) continue;
      if (ignore0) ignore0 = false;
      if (compress === index) {
        out += index === 0 ? '::' : ':';
        ignore0 = true;
        continue;
      }
      out += address[index].toString(16);
      if (index !== 7) out += ':';
    }
    return out;
  }
  function parseOpaqueHost(input) {
    if (FORBIDDEN_HOST.test(input)) return null;
    return encodeSet(input, EMPTY_SET);
  }
  function parseHost(input, special) {
    if (input.startsWith('[')) {
      if (!input.endsWith(']')) return null;
      const address = parseIPv6(input.slice(1, -1));
      return address === null ? null : '[' + serializeIPv6(address) + ']';
    }
    if (!special) return parseOpaqueHost(input);
    if (input === '') return null;
    const ascii = domainToASCII(percentDecode(input));
    if (ascii === null || FORBIDDEN_DOMAIN.test(ascii)) return null;
    if (endsInNumber(ascii)) {
      const address = parseIPv4(ascii);
      return address === null ? null : serializeIPv4(address);
    }
    return ascii;
  }

  function isWindowsDriveLetter(text, normalized) {
    return text.length === 2 && ASCII_ALPHA.test(text[0]) &&
      (text[1] === ':' || (!normalized && text[1] === '|'));
  }
  function startsWithWindowsDriveLetter(text) {
    return text.length >= 2 && isWindowsDriveLetter(text.slice(0, 2), false) &&
      (text.length === 2 || ['/', '\\', '?', '#'].includes(text[2]));
  }
  function shortenPath(url) {
    if (url.scheme === 'file' && url.path.length === 1 && isWindowsDriveLetter(url.path[0], true)) return;
    url.path.pop();
  }
  const isSingleDot = (segment) => {
    const lower = segment.toLowerCase();
    return lower === '.' || lower === '%2e';
  };
  const isDoubleDot = (segment) => {
    const lower = segment.toLowerCase();
    return lower === '..' || lower === '.%2e' || lower === '%2e.' || lower === '%2e%2e';
  };

  function newRecord() {
    return {
      scheme: '', username: '', password: '', host: null, port: null,
      path: [], query: null, fragment: null, opaque: false,
    };
  }

  // https://url.spec.whatwg.org/#concept-basic-url-parser
  function basicParse(rawInput, base = null, url = null, stateOverride = null) {
    let input = String(rawInput);
    if (url === null) {
      url = newRecord();
      input = input.replace(TRIM_C0_OR_SPACE, '');
    }
    input = input.replace(TAB_OR_NEWLINE, '');
    const chars = Array.from(input);
    const length = chars.length;
    let state = stateOverride === null ? 'scheme start' : stateOverride;
    let buffer = '';
    let atSignSeen = false;
    let insideBrackets = false;
    let passwordTokenSeen = false;

    for (let pointer = 0; pointer <= length; pointer++) {
      const c = pointer < length ? chars[pointer] : undefined;
      switch (state) {
        case 'scheme start':
          if (c !== undefined && ASCII_ALPHA.test(c)) {
            buffer += c.toLowerCase();
            state = 'scheme';
          } else if (stateOverride === null) {
            state = 'no scheme';
            pointer--;
          } else {
            return null;
          }
          break;

        case 'scheme':
          if (c !== undefined && SCHEME_CHAR.test(c)) {
            buffer += c.toLowerCase();
          } else if (c === ':') {
            if (stateOverride !== null) {
              if (isSpecial(url.scheme) !== isSpecial(buffer)) return url;
              if ((url.username !== '' || url.password !== '' || url.port !== null) && buffer === 'file') return url;
              if (url.scheme === 'file' && url.host === '') return url;
            }
            url.scheme = buffer;
            if (stateOverride !== null) {
              if (url.port === SPECIAL_PORTS[url.scheme]) url.port = null;
              return url;
            }
            buffer = '';
            if (url.scheme === 'file') {
              state = 'file';
            } else if (isSpecial(url.scheme) && base !== null && base.scheme === url.scheme) {
              state = 'special relative or authority';
            } else if (isSpecial(url.scheme)) {
              state = 'special authority slashes';
            } else if (chars[pointer + 1] === '/') {
              state = 'path or authority';
              pointer++;
            } else {
              url.opaque = true;
              url.path = '';
              state = 'opaque path';
            }
          } else if (stateOverride === null) {
            buffer = '';
            state = 'no scheme';
            pointer = -1;
          } else {
            return null;
          }
          break;

        case 'no scheme':
          if (base === null || (base.opaque && c !== '#')) return null;
          if (base.opaque && c === '#') {
            url.scheme = base.scheme;
            url.path = base.path;
            url.query = base.query;
            url.fragment = '';
            url.opaque = true;
            state = 'fragment';
          } else if (base.scheme !== 'file') {
            state = 'relative';
            pointer--;
          } else {
            state = 'file';
            pointer--;
          }
          break;

        case 'special relative or authority':
          if (c === '/' && chars[pointer + 1] === '/') {
            state = 'special authority ignore slashes';
            pointer++;
          } else {
            state = 'relative';
            pointer--;
          }
          break;

        case 'path or authority':
          if (c === '/') {
            state = 'authority';
          } else {
            state = 'path';
            pointer--;
          }
          break;

        case 'relative':
          url.scheme = base.scheme;
          if (c === '/' || (isSpecial(url.scheme) && c === '\\')) {
            state = 'relative slash';
          } else {
            url.username = base.username;
            url.password = base.password;
            url.host = base.host;
            url.port = base.port;
            url.path = base.path.slice();
            url.query = base.query;
            if (c === '?') {
              url.query = '';
              state = 'query';
            } else if (c === '#') {
              url.fragment = '';
              state = 'fragment';
            } else if (c !== undefined) {
              url.query = null;
              shortenPath(url);
              state = 'path';
              pointer--;
            }
          }
          break;

        case 'relative slash':
          if (isSpecial(url.scheme) && (c === '/' || c === '\\')) {
            state = 'special authority ignore slashes';
          } else if (c === '/') {
            state = 'authority';
          } else {
            url.username = base.username;
            url.password = base.password;
            url.host = base.host;
            url.port = base.port;
            state = 'path';
            pointer--;
          }
          break;

        case 'special authority slashes':
          if (c === '/' && chars[pointer + 1] === '/') {
            state = 'special authority ignore slashes';
            pointer++;
          } else {
            state = 'special authority ignore slashes';
            pointer--;
          }
          break;

        case 'special authority ignore slashes':
          if (c !== '/' && c !== '\\') {
            state = 'authority';
            pointer--;
          }
          break;

        case 'authority':
          if (c === '@') {
            if (atSignSeen) buffer = '%40' + buffer;
            atSignSeen = true;
            for (const char of buffer) {
              if (char === ':' && !passwordTokenSeen) {
                passwordTokenSeen = true;
                continue;
              }
              const encoded = encodeSet(char, USERINFO_SET);
              if (passwordTokenSeen) url.password += encoded;
              else url.username += encoded;
            }
            buffer = '';
          } else if (c === undefined || c === '/' || c === '?' || c === '#' ||
            (isSpecial(url.scheme) && c === '\\')) {
            if (atSignSeen && buffer === '') return null;
            pointer -= Array.from(buffer).length + 1;
            buffer = '';
            state = 'host';
          } else {
            buffer += c;
          }
          break;

        case 'host':
        case 'hostname':
          if (stateOverride !== null && url.scheme === 'file') {
            state = 'file host';
            pointer--;
          } else if (c === ':' && !insideBrackets) {
            if (buffer === '') return null;
            if (stateOverride === 'hostname') return url;
            const parsed = parseHost(buffer, isSpecial(url.scheme));
            if (parsed === null) return null;
            url.host = parsed;
            buffer = '';
            state = 'port';
          } else if (c === undefined || c === '/' || c === '?' || c === '#' ||
            (isSpecial(url.scheme) && c === '\\')) {
            pointer--;
            if (isSpecial(url.scheme) && buffer === '') return null;
            if (stateOverride !== null && buffer === '' &&
              (url.username !== '' || url.password !== '' || url.port !== null)) {
              return url;
            }
            const parsed = parseHost(buffer, isSpecial(url.scheme));
            if (parsed === null) return null;
            url.host = parsed;
            buffer = '';
            state = 'path start';
            if (stateOverride !== null) return url;
          } else {
            if (c === '[') insideBrackets = true;
            else if (c === ']') insideBrackets = false;
            buffer += c;
          }
          break;

        case 'port':
          if (c !== undefined && DIGITS.test(c)) {
            buffer += c;
          } else if (c === undefined || c === '/' || c === '?' || c === '#' ||
            (isSpecial(url.scheme) && c === '\\') || stateOverride !== null) {
            if (buffer !== '') {
              const port = parseInt(buffer, 10);
              if (port > 65535) return null;
              url.port = port === SPECIAL_PORTS[url.scheme] ? null : port;
              buffer = '';
            }
            if (stateOverride !== null) return url;
            state = 'path start';
            pointer--;
          } else {
            return null;
          }
          break;

        case 'file':
          url.scheme = 'file';
          url.host = '';
          if (c === '/' || c === '\\') {
            state = 'file slash';
          } else if (base !== null && base.scheme === 'file') {
            url.host = base.host;
            url.path = base.path.slice();
            url.query = base.query;
            if (c === '?') {
              url.query = '';
              state = 'query';
            } else if (c === '#') {
              url.fragment = '';
              state = 'fragment';
            } else if (c !== undefined) {
              url.query = null;
              if (!startsWithWindowsDriveLetter(chars.slice(pointer).join(''))) shortenPath(url);
              else url.path = [];
              state = 'path';
              pointer--;
            }
          } else {
            state = 'path';
            pointer--;
          }
          break;

        case 'file slash':
          if (c === '/' || c === '\\') {
            state = 'file host';
          } else {
            if (base !== null && base.scheme === 'file') {
              url.host = base.host;
              if (!startsWithWindowsDriveLetter(chars.slice(pointer).join('')) &&
                base.path.length > 0 && isWindowsDriveLetter(base.path[0], true)) {
                url.path.push(base.path[0]);
              }
            }
            state = 'path';
            pointer--;
          }
          break;

        case 'file host':
          if (c === undefined || c === '/' || c === '\\' || c === '?' || c === '#') {
            pointer--;
            if (stateOverride === null && isWindowsDriveLetter(buffer, false)) {
              state = 'path';
            } else if (buffer === '') {
              url.host = '';
              if (stateOverride !== null) return url;
              state = 'path start';
            } else {
              let parsed = parseHost(buffer, isSpecial(url.scheme));
              if (parsed === null) return null;
              if (parsed === 'localhost') parsed = '';
              url.host = parsed;
              if (stateOverride !== null) return url;
              buffer = '';
              state = 'path start';
            }
          } else {
            buffer += c;
          }
          break;

        case 'path start':
          if (isSpecial(url.scheme)) {
            state = 'path';
            if (c !== '/' && c !== '\\') pointer--;
          } else if (stateOverride === null && c === '?') {
            url.query = '';
            state = 'query';
          } else if (stateOverride === null && c === '#') {
            url.fragment = '';
            state = 'fragment';
          } else if (c !== undefined) {
            state = 'path';
            if (c !== '/') pointer--;
          } else if (stateOverride !== null && url.host === null) {
            url.path.push('');
          }
          break;

        case 'path':
          if (c === undefined || c === '/' || (isSpecial(url.scheme) && c === '\\') ||
            (stateOverride === null && (c === '?' || c === '#'))) {
            if (isDoubleDot(buffer)) {
              shortenPath(url);
              if (c !== '/' && !(isSpecial(url.scheme) && c === '\\')) url.path.push('');
            } else if (isSingleDot(buffer)) {
              if (c !== '/' && !(isSpecial(url.scheme) && c === '\\')) url.path.push('');
            } else {
              if (url.scheme === 'file' && url.path.length === 0 && isWindowsDriveLetter(buffer, false)) {
                buffer = buffer[0] + ':';
              }
              url.path.push(buffer);
            }
            buffer = '';
            if (c === '?') {
              url.query = '';
              state = 'query';
            } else if (c === '#') {
              url.fragment = '';
              state = 'fragment';
            }
          } else {
            buffer += encodeSet(c, PATH_SET);
          }
          break;

        case 'opaque path':
          if (c === '?') {
            url.query = '';
            state = 'query';
          } else if (c === '#') {
            url.fragment = '';
            state = 'fragment';
          } else if (c !== undefined) {
            url.path += encodeSet(c, EMPTY_SET);
          }
          break;

        case 'query':
          if (c === undefined || (stateOverride === null && c === '#')) {
            url.query += encodeSet(buffer, isSpecial(url.scheme) ? SPECIAL_QUERY_SET : QUERY_SET);
            buffer = '';
            if (c === '#') {
              url.fragment = '';
              state = 'fragment';
            }
          } else {
            buffer += c;
          }
          break;

        case 'fragment':
          if (c !== undefined) url.fragment += encodeSet(c, FRAGMENT_SET);
          break;

        default:
          return null;
      }
    }
    return url;
  }

  function serializePath(url) {
    return url.opaque ? url.path : url.path.length === 0 ? '' : '/' + url.path.join('/');
  }
  function serializeHost(url) {
    if (url.host === null) return '';
    return url.port === null ? url.host : url.host + ':' + url.port;
  }
  function serializeURL(url, excludeFragment = false) {
    let out = url.scheme + ':';
    if (url.host !== null) {
      out += '//';
      if (url.username !== '' || url.password !== '') {
        out += url.username;
        if (url.password !== '') out += ':' + url.password;
        out += '@';
      }
      out += serializeHost(url);
    } else if (!url.opaque && url.path.length > 1 && url.path[0] === '') {
      out += '/.';
    }
    out += serializePath(url);
    if (url.query !== null) out += '?' + url.query;
    if (!excludeFragment && url.fragment !== null) out += '#' + url.fragment;
    return out;
  }
  function serializeOrigin(url) {
    switch (url.scheme) {
      case 'ftp':
      case 'http':
      case 'https':
      case 'ws':
      case 'wss':
        return url.scheme + '://' + serializeHost(url);
      case 'blob': {
        const inner = basicParse(serializePath(url));
        return inner === null ? 'null' : serializeOrigin(inner);
      }
      default:
        return 'null';
    }
  }

  function invalidURL(input, base) {
    return new TypeError('Invalid URL: ' + input + (base === undefined ? '' : ' (base: ' + base + ')'));
  }

  // ---- application/x-www-form-urlencoded ----
  function serializeFormUrlencoded(pairs) {
    const encode = (text) => {
      const bytes = natives.utf8Encode(text);
      let out = '';
      for (let i = 0; i < bytes.length; i++) {
        const byte = bytes[i];
        if (byte === 0x20) {
          out += '+';
        } else if (byte === 0x2a || byte === 0x2d || byte === 0x2e || byte === 0x5f ||
          (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5a) ||
          (byte >= 0x61 && byte <= 0x7a)) {
          out += String.fromCharCode(byte);
        } else {
          out += '%' + byte.toString(16).toUpperCase().padStart(2, '0');
        }
      }
      return out;
    };
    let out = '';
    for (const pair of pairs) {
      if (out !== '') out += '&';
      out += encode(pair[0]) + '=' + encode(pair[1]);
    }
    return out;
  }
  function parseFormUrlencoded(input) {
    const pairs = [];
    for (const piece of input.split('&')) {
      if (piece === '') continue;
      const index = piece.indexOf('=');
      const name = index < 0 ? piece : piece.slice(0, index);
      const value = index < 0 ? '' : piece.slice(index + 1);
      pairs.push([percentDecode(name.replace(/\+/g, ' ')), percentDecode(value.replace(/\+/g, ' '))]);
    }
    return pairs;
  }

  let createSearchParams;
  let searchParamsPairs;
  let setSearchParamsPairs;
  class URLSearchParams {
    #pairs = [];
    #url = null;

    constructor(init = undefined) {
      if (init === undefined || init === null) return;
      if (typeof init === 'string') {
        this.#pairs = parseFormUrlencoded(init.startsWith('?') ? init.slice(1) : init);
      } else if (typeof init === 'object' && typeof init[Symbol.iterator] === 'function') {
        for (const entry of init) {
          const pair = Array.from(entry);
          if (pair.length !== 2) {
            throw new TypeError("Failed to construct 'URLSearchParams': Sequence initializer must only contain pair elements.");
          }
          this.#pairs.push([String(pair[0]), String(pair[1])]);
        }
      } else if (typeof init === 'object') {
        for (const key of Object.keys(init)) this.#pairs.push([key, String(init[key])]);
      } else {
        this.#pairs = parseFormUrlencoded(String(init));
      }
    }

    #update() {
      if (this.#url === null) return;
      const serialized = serializeFormUrlencoded(this.#pairs);
      this.#url.record.query = serialized === '' ? null : serialized;
    }
    get size() { return this.#pairs.length; }
    append(name, value) {
      if (arguments.length < 2) {
        throw new TypeError("Failed to execute 'append' on 'URLSearchParams': 2 arguments required.");
      }
      this.#pairs.push([String(name), String(value)]);
      this.#update();
    }
    delete(name, value = undefined) {
      const key = String(name);
      const hasValue = value !== undefined;
      const text = hasValue ? String(value) : '';
      this.#pairs = this.#pairs.filter((pair) => !(pair[0] === key && (!hasValue || pair[1] === text)));
      this.#update();
    }
    get(name) {
      const key = String(name);
      for (const pair of this.#pairs) if (pair[0] === key) return pair[1];
      return null;
    }
    getAll(name) {
      const key = String(name);
      return this.#pairs.filter((pair) => pair[0] === key).map((pair) => pair[1]);
    }
    has(name, value = undefined) {
      const key = String(name);
      const hasValue = value !== undefined;
      const text = hasValue ? String(value) : '';
      return this.#pairs.some((pair) => pair[0] === key && (!hasValue || pair[1] === text));
    }
    set(name, value) {
      if (arguments.length < 2) {
        throw new TypeError("Failed to execute 'set' on 'URLSearchParams': 2 arguments required.");
      }
      const key = String(name);
      const text = String(value);
      let found = false;
      const next = [];
      for (const pair of this.#pairs) {
        if (pair[0] !== key) {
          next.push(pair);
          continue;
        }
        if (found) continue;
        found = true;
        next.push([key, text]);
      }
      if (!found) next.push([key, text]);
      this.#pairs = next;
      this.#update();
    }
    sort() {
      this.#pairs.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
      this.#update();
    }
    forEach(callback, thisArg = undefined) {
      for (const pair of this.#pairs.slice()) callback.call(thisArg, pair[1], pair[0], this);
    }
    *entries() { for (const pair of this.#pairs.slice()) yield [pair[0], pair[1]]; }
    *keys() { for (const pair of this.#pairs.slice()) yield pair[0]; }
    *values() { for (const pair of this.#pairs.slice()) yield pair[1]; }
    [Symbol.iterator]() { return this.entries(); }
    toString() { return serializeFormUrlencoded(this.#pairs); }
    [customInspect]() {
      const body = this.#pairs.map((pair) => JSON.stringify(pair[0]) + ' => ' + JSON.stringify(pair[1])).join(', ');
      return body === '' ? 'URLSearchParams {}' : 'URLSearchParams { ' + body + ' }';
    }
    static {
      createSearchParams = (url, query) => {
        const params = new URLSearchParams(query === null ? '' : query);
        params.#url = url;
        return params;
      };
      searchParamsPairs = (params) => params.#pairs;
      setSearchParamsPairs = (params, pairs) => { params.#pairs = pairs; };
    }
  }
  Object.defineProperty(URLSearchParams.prototype, Symbol.toStringTag, { value: 'URLSearchParams', configurable: true });

  let urlRecord;
  let createURL;
  class URL {
    #record;
    #params;

    constructor(url, base = undefined) {
      // Internal construction from an existing URL record.
      if (url === illegal) {
        this.#record = base;
        this.#params = createSearchParams(this, base.query);
        return;
      }
      if (arguments.length === 0) {
        throw new TypeError("Failed to construct 'URL': 1 argument required, but only 0 present.");
      }
      let baseRecord = null;
      if (base !== undefined) {
        baseRecord = basicParse(base);
        if (baseRecord === null) throw invalidURL(url, base);
      }
      const record = basicParse(url, baseRecord);
      if (record === null) throw invalidURL(url, base);
      this.#record = record;
      this.#params = createSearchParams(this, record.query);
    }
    get record() { return this.#record; }
    static parse(url, base = undefined) {
      try {
        return new URL(url, base);
      } catch (e) {
        return null;
      }
    }
    static canParse(url, base = undefined) { return URL.parse(url, base) !== null; }

    get href() { return serializeURL(this.#record); }
    set href(value) {
      const record = basicParse(value);
      if (record === null) throw invalidURL(value);
      this.#record = record;
      setSearchParamsPairs(this.#params, parseFormUrlencoded(record.query === null ? '' : record.query));
    }
    toString() { return this.href; }
    toJSON() { return this.href; }
    get origin() { return serializeOrigin(this.#record); }
    get protocol() { return this.#record.scheme + ':'; }
    set protocol(value) { basicParse(String(value) + ':', null, this.#record, 'scheme start'); }
    get username() { return this.#record.username; }
    set username(value) {
      if (this.#record.host === null || this.#record.host === '' || this.#record.opaque) return;
      this.#record.username = encodeSet(String(value), USERINFO_SET);
    }
    get password() { return this.#record.password; }
    set password(value) {
      if (this.#record.host === null || this.#record.host === '' || this.#record.opaque) return;
      this.#record.password = encodeSet(String(value), USERINFO_SET);
    }
    get host() { return serializeHost(this.#record); }
    set host(value) {
      if (this.#record.opaque) return;
      basicParse(String(value), null, this.#record, 'host');
    }
    get hostname() { return this.#record.host === null ? '' : this.#record.host; }
    set hostname(value) {
      if (this.#record.opaque) return;
      basicParse(String(value), null, this.#record, 'hostname');
    }
    get port() { return this.#record.port === null ? '' : String(this.#record.port); }
    set port(value) {
      const record = this.#record;
      if (record.host === null || record.host === '' || record.opaque || record.scheme === 'file') return;
      const text = String(value);
      if (text === '') record.port = null;
      else basicParse(text, null, record, 'port');
    }
    get pathname() { return serializePath(this.#record); }
    set pathname(value) {
      if (this.#record.opaque) return;
      this.#record.path = [];
      basicParse(String(value), null, this.#record, 'path start');
    }
    get search() {
      const query = this.#record.query;
      return query === null || query === '' ? '' : '?' + query;
    }
    set search(value) {
      const record = this.#record;
      const text = String(value);
      if (text === '') {
        record.query = null;
        setSearchParamsPairs(this.#params, []);
        return;
      }
      record.query = '';
      basicParse(text.startsWith('?') ? text.slice(1) : text, null, record, 'query');
      setSearchParamsPairs(this.#params, parseFormUrlencoded(record.query));
    }
    get searchParams() { return this.#params; }
    get hash() {
      const fragment = this.#record.fragment;
      return fragment === null || fragment === '' ? '' : '#' + fragment;
    }
    set hash(value) {
      const text = String(value);
      if (text === '') {
        this.#record.fragment = null;
        return;
      }
      this.#record.fragment = '';
      basicParse(text.startsWith('#') ? text.slice(1) : text, null, this.#record, 'fragment');
    }
    [customInspect]() { return 'URL { href: ' + JSON.stringify(this.href) + ' }'; }
    static {
      urlRecord = (value) => (typeof value === 'object' && value !== null && #record in value ? value.#record : null);
      createURL = (record) => new URL(illegal, record);
    }
  }
  Object.defineProperty(URL.prototype, Symbol.toStringTag, { value: 'URL', configurable: true });

  cloneHooks.push((value) => {
    if (urlRecord(value) !== null) {
      throw new DOMException('URL could not be cloned.', 'DataCloneError');
    }
    return NOT_CLONED;
  });

  Object.assign(internal, {
    URL, URLSearchParams, parseURL: basicParse, serializeURL, serializeFormUrlencoded,
    parseFormUrlencoded, percentDecode, urlRecord, createURL, searchParamsPairs,
    setSearchParamsPairs, createSearchParams,
  });

  define(g, 'URL', URL);
  define(g, 'URLSearchParams', URLSearchParams);
})
''';
