import type { CategoryOption, SessionState } from './types'
import { getSupabaseClient } from './supabase'

type SubmitAnswerInput = {
  code: string
  playerToken: string
  questionId: number
  passed: boolean
  answerText: string | null
  answerChoice: string | null
  answerScale: number | null
}

async function rpc<T>(fn: string, params?: Record<string, unknown>) {
  const supabase = getSupabaseClient()
  const { data, error } = await supabase.rpc(fn, params)

  if (error) {
    throw new Error(error.message)
  }

  return data as T
}

export async function listCategories() {
  return rpc<CategoryOption[]>('list_categories')
}

export async function createSession(category: string, playerToken: string) {
  return rpc<SessionState>('create_session', {
    p_category: category,
    p_player_token: playerToken,
    p_max_nsfw_level: 2,
  })
}

export async function joinSession(code: string, playerToken: string) {
  return rpc<SessionState>('join_session', {
    p_code: code,
    p_player_token: playerToken,
  })
}

export async function getSessionState(code: string, playerToken: string) {
  return rpc<SessionState>('get_session_state', {
    p_code: code,
    p_player_token: playerToken,
  })
}

export async function setReady(code: string, playerToken: string) {
  return rpc<SessionState>('set_ready', {
    p_code: code,
    p_player_token: playerToken,
  })
}

export async function submitAnswer(input: SubmitAnswerInput) {
  return rpc<SessionState>('submit_answer', {
    p_code: input.code,
    p_player_token: input.playerToken,
    p_question_id: input.questionId,
    p_passed: input.passed,
    p_answer_text: input.answerText,
    p_answer_choice: input.answerChoice,
    p_answer_scale: input.answerScale,
  })
}

export async function pickRevealQuestions(
  code: string,
  playerToken: string,
  questionIds: number[],
) {
  return rpc<SessionState>('pick_reveal_questions', {
    p_code: code,
    p_player_token: playerToken,
    p_question_ids: questionIds,
  })
}

export async function advanceReveal(code: string, playerToken: string) {
  return rpc<SessionState>('advance_reveal', {
    p_code: code,
    p_player_token: playerToken,
  })
}
