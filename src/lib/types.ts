export type SessionStatus =
  | 'waiting_partner'
  | 'ready'
  | 'in_progress'
  | 'pick_reveal'
  | 'reveal'
  | 'ended'

export type PlayerSlot = 'A' | 'B'

export type AnswerPayload = {
  passed: boolean
  text: string | null
  choice: string | null
  scale: number | null
}

export type CurrentQuestion = {
  id: number
  position: number
  type: 'text' | 'qcm' | 'scale'
  prompt: string
  options: string[]
  scaleMin: number
  scaleMax: number
  selfAnswer: AnswerPayload | null
  selfDone: boolean
  partnerDone: boolean
}

export type PickRevealQuestion = {
  id: number
  position: number
  prompt: string
  type: 'text' | 'qcm' | 'scale'
  selectedBySelf: boolean
}

export type RevealPayload = {
  total: number
  index: number
  selfCompleted: boolean
  partnerCompleted: boolean
  current: {
    position: number
    questionId: number
    prompt: string
    partnerAnswer: AnswerPayload
  } | null
}

export type SessionState = {
  session: {
    code: string
    category: string
    status: SessionStatus
    playerSlot: PlayerSlot
    currentIndex: number
    revealIndex: number
  }
  presence: {
    partnerJoined: boolean
    selfReady: boolean
    partnerReady: boolean
    partnerConnected: boolean
  }
  currentQuestion: CurrentQuestion | null
  pickReveal: {
    questions: PickRevealQuestion[]
    pickedCountSelf: number
    pickedCountPartner: number
  } | null
  reveal: RevealPayload | null
}

export type CategoryOption = {
  category: string
  count: number
  maxNsfwLevel: number
}
