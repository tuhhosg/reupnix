
export const TXT = {
	/**
	 * Formats an array of uniform objects as a human readable text table.
	 *
	 * @example
	 * const preContent = encodeHtml(TXT.stringify({
	 *     columns: { date: '^9', method: '^meth', host: '8^', path: '40^', ua: '^50' },
	 *     entries: [ ... ],
	 * });
	 *
	 * @return  Plain text table as multi line string.
	 */
	stringify<EntryT extends Record<string, unknown>>({
		columns, entries, stringify = null, ellipsis = '…', separator = ' ', delimiter = '\r\n', finalize = null,
	}: {
		/** Object whose properties define the columns of the table.
		 *  Each column's values will be the entries' properties of the same name,
		 *  formatted according to the values properties as follows:
		 *      .limit: maximum width of the column, longer values will be trimmed.
		 *      .align: true to align right, left otherwise,
		 *      .trim: true to trim left, right otherwise. Defaults to `.align`.
		 *      .name: Header name of the column. Defaults to the property name.
		 *  As shortcuts, the value can be a number specifying only the `.limit`
		 *  or a string `[align]?[limit[trim]?]? ?[name]?`, where `align` and `trim`
		 *  may be `^` or `$` for left and right, respectively, `limit` is a decimal
		 *  number, and `name` is any string (prefix it with a/another space if it
		 *  should start with `^`, `$` or a digit or space).
		 *  A `null`ish value will ignore that column. */
		columns: { [key in keyof EntryT]: number | string | { limit?: number, align?: boolean, trim?: boolean, name?: string, } | null; },
		/** Array of objects to fill the table. */
		entries: EntryT[],
		/** Stringification function invoked as `string = *(value, key, entry)`
		 *  to cast each used value into strings before taking their lengths.
		 *  The default prints primitives and `ObjectId`s as `+''`,
		 *  `Date`s as ISO dates, and other objects as `JSON5`. */
		stringify?: ((value: EntryT[keyof EntryT], key: keyof EntryT, entry: EntryT) => string) | null,
		/** Function called on each stringified and padded/trimmed value, before
		 *  placing it in its cell. E.g. useful for syntax highlighting in HTML. */
		finalize?:  ((value: string,               key: keyof EntryT, entry: EntryT) => string) | null,
		/** String placed at the cropped end of values.
		 *  Must be shorter than the smallest column width. Defaults to `…`. */
		ellipsis?: string,
		/** Column separator. Defaults to ` ` (space). */
		separator?: string,
		/** Line break. Defaults to `\r\n`. */
		delimiter?: string,
	}): string {
		!finalize && (finalize = x => x);
		!stringify && (stringify = value => {
			if (value == null) { return  value +'' /*value === null ? '\u2400' : '\u2205'*/; }
			if (typeof value !== 'object') { return value +''; }
			if (value instanceof Date) { return isFinite(+value) ? value.toISOString().replace('T', '').replace(/(?:[.]000)?Z$/, '') : 'Invalid Date'; }
			return JSON.stringify(value);
		});
		const width = Object.keys(columns).length, height = entries.length;
		const header = new Array(width);
		const body = new Array(height); for (let i = 0; i < height; ++i) { body[i] = new Array(width); }

		Object.entries(columns).forEach(([ key, props, ], col) => {
			if (props == null) { return; }
			if (typeof props === 'number') { props = { limit: props, }; }
			if (typeof props === 'string') {
				const [ , align, limit, trim, name, ] = (/^([$^])?(?:(\d+)([$^])?)? ?(.*?)?$/).exec(props) || [ ];
				props = {
					name: name || key, limit: limit == null ? -1 : +limit,
					align: align === '$', trim: trim ? trim === '^' : align === '$',
				};
			}
			const { align = false, limit = -1, } = props, { trim = align, name = key, } = props;
			if (limit === 0) { header[col] = separator; body.forEach(_=>(_[col] = separator)); return; }

			let max = name.length; entries.forEach((entry, row) => {
				const value = body[row][col] = stringify!(entry[key as keyof EntryT], key, entry);
				max = Math.max(max, value.length);
			});
			max = limit < 0 ? max : Math.min(limit, max);
			const pre = col === 0 ? '' : separator, elp = ellipsis.length < max ? ellipsis : '';
			entries.forEach((entry, row) => {
				body[row][col] = pre + finalize!(trimAlign(body[row][col]), key, entry);
			}); header[col] = pre + trimAlign(name);

			function trimAlign(value: string) {
				return value.length > max
				? trim ? elp + value.slice(-max + elp.length) : value.slice(0, max - elp.length) + elp
				: align ? value.padStart(max) : value.padEnd(max);
			}
		});

		return header.join('') + delimiter + body.map(row => row.join('')).join(delimiter);
	},
};

export const CSV = {
	/**
	 * Serializes an optional header and a number of records as a RFC 4180-compliant CSV-file string.
	 *
	 * @example
	 * const csvBuffer = Buffer.from('\ufeff'+ CSV.stringify({
	 *     header: { name: 'Name', age: 'Age', },
	 *     records: [ { name: 'Dad', age: 42, }, { name: 'Baby', age: '1', }, ],
	 *     separator: ';',
	 * }) +'\r\n', 'utf-8');
	 *
	 * @return  (Depending on the options) RFC 4180-compliant CSV-file string, without final delimiter.
	 */
	stringify<RecordT extends Record<string, unknown>>({
		header = null, records, serialize = null, stringify = null, separator = ',', delimiter = '\r\n',
	}: {
		/** Optional. Header row as `[ ...keys, ]` or `{ [key]: name, ... }`.
		 *  Fields with `name == null` will be ignored. If `.serialize` is unset,
		 *  non-Array records are mapped to their property values of the provided keys. */
		header?: (keyof RecordT)[] | { [key in keyof RecordT]?: string | null; } | null,
		/** Iterable of records. Each record passed is mapped through `.serialize`. */
		records: (RecordT | RecordT[keyof RecordT][])[],
		/** Serialization function `(record) => [ ...values, ]`.
		 *  Must return a constant-length iterable of values for each record.
		 *  Defaults to the id function or what is described under `.header`. */
		serialize?: ((record: RecordT | RecordT[keyof RecordT][]) => RecordT[keyof RecordT][]) | null,
		/** Optional stringification function that is invoked for every value (returned by `serialize`).
		 *  The default function keeps numbers, omits null/undefined and casts everything else into strings.
		 *  The default behavior may be adjusted by passing an object with the following properties instead:
		 *      `.tabPrefix`: Optional `RegExp`, defaulting to `/\d/` if not set. Values matching
		 *      this will be prefixed with a `'\t'`. This is done to prevent MS Office from
		 *      interpreting string numbers as numerical values, messing up their string formatting.
		 *      This may cause other applications to read the additional '\t'.
		 *      `.quote`: `RegExp`, defaulting to `/[<separator><delimiter>,;\t\r\n"]/` if not set.
		 *      Matching values will be surrounded with double quotes and have internal double quotes duplicated.
		 *  which are surrounded with quotes and prefixed when necessary. */
		stringify?: ((value: RecordT[keyof RecordT], index: number/* , record: RecordT[keyof RecordT][] */) => string) | { tabPrefix?: RegExp|false, quote?: RegExp, } | null,
		/** Value separator within record lines. Defaults to `,`. */
		separator?: string,
		/** Record/line delimiter. Defaults to `\r\n`. */
		delimiter?: string,
	}): string {
		if (typeof header === 'object' && header !== null) {
			const fields = Array.isArray(header) ? header : Object.keys(header).filter(key => header![key] != null);
			!Array.isArray(header) && (header = fields.map(key => header![key as any]));
			!serialize && (serialize = obj => Array.isArray(obj) ? obj : fields.map(_=>obj[_]));
		}
		!serialize && (serialize = (x: any) => x);
		if (typeof stringify !== 'function') {
			const {
				tabPrefix = (/\d/),
				quote = new RegExp(String.raw`[${ separator + delimiter },;\t\r\n"]`),
			} = stringify || { };
			stringify = value => {
				if (value == null) { return ''; } if (typeof value === 'number') { return value +''; } let _value = value +'';
				if (tabPrefix && tabPrefix.test(_value)) { _value = '\t'+ _value; } // see https://superuser.com/a/704291
				return quote.test(_value) ? '"'+ _value.split('"').join('""') + '"' : _value;
			};
		}
		function record(values: RecordT | RecordT[keyof RecordT][]) { return Array.from(serialize!(values), stringify as any).join(separator); }
		return (header ? record(header as any) + delimiter : '') + Array.from(records, record).join(delimiter);
	},
};
