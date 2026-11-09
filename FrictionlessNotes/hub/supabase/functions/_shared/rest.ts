// A very small PostgREST client with the subset of the supabase-js surface the
// hub uses (rpc, select/eq/gt/gte/in/order/limit/maybeSingle/single, insert,
// upsert, update, delete). Fetch only, no dependencies, so each edge function
// bundles to a few dozen kilobytes. Every call resolves to { data, error }.

export interface RestError { message: string; code?: string; details?: string; hint?: string; status: number }
export type Result<T = any> = { data: T; error: null } | { data: null; error: RestError };

export class Rest {
  constructor(private url: string, private key: string) {}

  private headers(extra: Record<string, string> = {}): Record<string, string> {
    return { apikey: this.key, authorization: `Bearer ${this.key}`, "content-type": "application/json", ...extra };
  }

  async rpc<T = any>(fn: string, args: Record<string, unknown> = {}): Promise<Result<T>> {
    const res = await fetch(`${this.url}/rest/v1/rpc/${fn}`, { method: "POST", headers: this.headers(), body: JSON.stringify(args) });
    return await parse<T>(res);
  }

  from(table: string): Query {
    return new Query(this.url, this.key, table);
  }
}

async function parse<T>(res: Response): Promise<Result<T>> {
  const text = await res.text();
  if (!res.ok) {
    let body: any = {};
    try { body = JSON.parse(text); } catch { body = { message: text }; }
    return { data: null, error: { message: body.message ?? text ?? res.statusText, code: body.code, details: body.details, hint: body.hint, status: res.status } };
  }
  if (!text) return { data: null as unknown as T, error: null };
  try {
    return { data: JSON.parse(text) as T, error: null };
  } catch {
    return { data: text as unknown as T, error: null };
  }
}

type Op = "select" | "insert" | "upsert" | "update" | "delete";

export class Query implements PromiseLike<Result<any>> {
  private op: Op = "select";
  private columns = "*";
  private filters: string[] = [];
  private orderBy: string[] = [];
  private limitN: number | null = null;
  private body: unknown = undefined;
  private singleMode: "maybe" | "one" | null = null;
  private returning = false;

  constructor(private url: string, private key: string, private table: string) {}

  select(columns = "*"): this {
    if (this.op === "select") this.columns = columns;
    else { this.columns = columns; this.returning = true; }
    return this;
  }
  insert(rows: unknown): this { this.op = "insert"; this.body = rows; return this; }
  upsert(rows: unknown): this { this.op = "upsert"; this.body = rows; return this; }
  update(values: unknown): this { this.op = "update"; this.body = values; return this; }
  delete(): this { this.op = "delete"; return this; }

  eq(col: string, v: unknown): this { this.filters.push(`${col}=eq.${enc(v)}`); return this; }
  neq(col: string, v: unknown): this { this.filters.push(`${col}=neq.${enc(v)}`); return this; }
  gt(col: string, v: unknown): this { this.filters.push(`${col}=gt.${enc(v)}`); return this; }
  gte(col: string, v: unknown): this { this.filters.push(`${col}=gte.${enc(v)}`); return this; }
  lt(col: string, v: unknown): this { this.filters.push(`${col}=lt.${enc(v)}`); return this; }
  is(col: string, v: null | boolean): this { this.filters.push(`${col}=is.${v === null ? "null" : v}`); return this; }
  in(col: string, vs: unknown[]): this {
    this.filters.push(`${col}=in.(${vs.map((v) => `"${String(v).replace(/"/g, '\\"')}"`).join(",")})`);
    return this;
  }
  order(col: string, opts: { ascending?: boolean } = {}): this { this.orderBy.push(`${col}.${opts.ascending === false ? "desc" : "asc"}`); return this; }
  limit(n: number): this { this.limitN = n; return this; }
  maybeSingle(): this { this.singleMode = "maybe"; return this; }
  single(): this { this.singleMode = "one"; return this; }

  private async run(): Promise<Result<any>> {
    const params = [...this.filters];
    if (this.op === "select") params.push(`select=${this.columns}`);
    else if (this.returning) params.push(`select=${this.columns}`);
    for (const o of this.orderBy) params.push(`order=${o}`);
    if (this.limitN !== null) params.push(`limit=${this.limitN}`);
    const url = `${this.url}/rest/v1/${this.table}${params.length ? "?" + params.join("&") : ""}`;
    const prefer: string[] = [];
    if (this.op === "upsert") prefer.push("resolution=merge-duplicates");
    if (this.op !== "select") prefer.push(this.returning ? "return=representation" : "return=minimal");
    if (this.singleMode) prefer.push("count=none");
    const headers: Record<string, string> = { apikey: this.key, authorization: `Bearer ${this.key}`, "content-type": "application/json" };
    if (prefer.length) headers["prefer"] = prefer.join(",");
    if (this.singleMode === "one") headers["accept"] = "application/vnd.pgrst.object+json";
    const method = this.op === "select" ? "GET" : this.op === "insert" || this.op === "upsert" ? "POST" : this.op === "update" ? "PATCH" : "DELETE";
    if ((this.op === "delete" || this.op === "update") && this.filters.length === 0) {
      return { data: null, error: { message: `refusing to ${this.op} ${this.table} without a filter`, status: 400 } };
    }
    const res = await fetch(url, { method, headers, body: this.body === undefined ? undefined : JSON.stringify(this.body) });
    const r = await parse<any>(res);
    if (r.error) return r;
    if (this.singleMode === "maybe") {
      const d = Array.isArray(r.data) ? (r.data[0] ?? null) : r.data;
      return { data: d, error: null };
    }
    return r;
  }

  then<R1 = Result<any>, R2 = never>(onfulfilled?: ((v: Result<any>) => R1 | PromiseLike<R1>) | null, onrejected?: ((reason: any) => R2 | PromiseLike<R2>) | null): PromiseLike<R1 | R2> {
    return this.run().then(onfulfilled, onrejected);
  }
}

function enc(v: unknown): string {
  return encodeURIComponent(String(v));
}
