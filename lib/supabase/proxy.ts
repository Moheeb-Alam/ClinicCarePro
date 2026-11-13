import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

export async function updateSession(request: NextRequest) {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  if (!url || !key) return NextResponse.next({ request });

  let response = NextResponse.next({ request });
  const supabase = createServerClient(url, key, {
    cookies: {
      getAll() { return request.cookies.getAll(); },
      setAll(cookiesToSet) {
        cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
        response = NextResponse.next({ request });
        cookiesToSet.forEach(({ name, value, options }) => response.cookies.set(name, value, options));
      },
    },
  });

  // Read the cookie locally on every request. Only contact Auth to refresh a
  // session that is close to expiry, avoiding the old extra network call.
  const { data: { session } } = await supabase.auth.getSession();
  const nowSeconds = Math.floor(Date.now() / 1000);
  if (session?.expires_at && session.expires_at <= nowSeconds + 5 * 60) {
    await supabase.auth.refreshSession();
  }

  return response;
}
