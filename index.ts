// supabase/functions/refresh-fx/index.ts
// Deploy: supabase functions deploy refresh-fx
// Schedule via Supabase Dashboard → Edge Functions → Cron (every 6h)
//   Cron expression: 0 */6 * * *

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SUPABASE_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

Deno.serve(async (_req) => {
  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY)

    // Fetch live rates from exchangerate-api (free tier, no key needed)
    const res = await fetch('https://api.exchangerate-api.com/v4/latest/USD')
    if (!res.ok) throw new Error(`FX API error: ${res.status}`)
    const data = await res.json()

    const rates = [
      { base: 'USD', currency: 'USD', rate: 1.0 },
      { base: 'USD', currency: 'SGD', rate: data.rates.SGD },
      { base: 'USD', currency: 'INR', rate: data.rates.INR },
    ]

    const { error } = await supabase
      .from('fx_rates')
      .upsert(rates, { onConflict: 'base,currency' })

    if (error) throw error

    // Also trigger a net worth snapshot for all households
    await supabase.rpc('take_net_worth_snapshot')

    return new Response(JSON.stringify({
      ok: true,
      rates,
      timestamp: new Date().toISOString()
    }), { headers: { 'Content-Type': 'application/json' } })

  } catch (err) {
    return new Response(JSON.stringify({ ok: false, error: String(err) }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' }
    })
  }
})
