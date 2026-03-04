import { createClient } from '@supabase/supabase-js'

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

export const isSupabaseConfigured = Boolean(supabaseUrl && supabaseAnonKey)

const client = isSupabaseConfigured
  ? createClient(supabaseUrl, supabaseAnonKey, {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
      },
    })
  : null

export function getSupabaseClient() {
  if (!client) {
    throw new Error(
      'Supabase n est pas configure. Ajoute VITE_SUPABASE_URL et VITE_SUPABASE_ANON_KEY.',
    )
  }

  return client
}
