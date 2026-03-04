import {
  startTransition,
  useEffect,
  useEffectEvent,
  useMemo,
  useRef,
  useState,
} from 'react'
import './App.css'
import {
  advanceReveal,
  createSession,
  getSessionState,
  joinSession,
  listCategories,
  pickRevealQuestions,
  setReady,
  submitAnswer,
} from './lib/gameApi'
import {
  clearStoredSessionCode,
  getOrCreatePlayerToken,
  readStoredSessionCode,
  storeSessionCode,
} from './lib/storage'
import { isSupabaseConfigured } from './lib/supabase'
import type {
  AnswerPayload,
  CategoryOption,
  PickRevealQuestion,
  SessionState,
} from './lib/types'

type HomeMode = 'menu' | 'create' | 'join'

const POLL_INTERVAL_MS = 2500

function App() {
  const playerToken = useRef(getOrCreatePlayerToken()).current
  const lastQuestionIdRef = useRef<number | null>(null)
  const pickScreenInitializedRef = useRef(false)
  const [homeMode, setHomeMode] = useState<HomeMode>('menu')
  const [categories, setCategories] = useState<CategoryOption[]>([])
  const [categoriesLoading, setCategoriesLoading] = useState(false)
  const [categoriesError, setCategoriesError] = useState<string | null>(null)
  const [sessionCode, setSessionCode] = useState<string | null>(
    readStoredSessionCode,
  )
  const [sessionState, setSessionState] = useState<SessionState | null>(null)
  const [screenError, setScreenError] = useState<string | null>(null)
  const [busyLabel, setBusyLabel] = useState<string | null>(null)
  const [joinCode, setJoinCode] = useState('')
  const [selectedCategory, setSelectedCategory] = useState('')
  const [textDraft, setTextDraft] = useState('')
  const [choiceDraft, setChoiceDraft] = useState<string | null>(null)
  const [scaleDraft, setScaleDraft] = useState<number | null>(null)
  const [pickSelection, setPickSelection] = useState<number[]>([])

  const currentQuestion = sessionState?.currentQuestion ?? null
  const revealData = sessionState?.reveal ?? null
  const pickRevealData = sessionState?.pickReveal ?? null

  const selfLabel = useMemo(
    () => (sessionState?.session.playerSlot === 'A' ? 'Toi (A)' : 'Toi (B)'),
    [sessionState?.session.playerSlot],
  )
  const partnerLabel = useMemo(
    () =>
      sessionState?.session.playerSlot === 'A'
        ? 'Partenaire (B)'
        : 'Partenaire (A)',
    [sessionState?.session.playerSlot],
  )

  const applySessionState = (nextState: SessionState | null) => {
    startTransition(() => {
      setSessionState(nextState)

      if (nextState) {
        storeSessionCode(nextState.session.code)
        setSessionCode(nextState.session.code)
      } else {
        clearStoredSessionCode()
        setSessionCode(null)
      }
    })
  }

  const handleFailure = (error: unknown) => {
    const message =
      error instanceof Error ? error.message : 'Une erreur inattendue est survenue.'

    if (message.includes('SESSION_NOT_FOUND')) {
      clearStoredSessionCode()
      setSessionCode(null)
      setSessionState(null)
      setHomeMode('menu')
      setScreenError(
        'La session a expire ou a ete supprimee apres un timeout de presence.',
      )
      return
    }

    setScreenError(message)
  }

  const loadCategories = useEffectEvent(async () => {
    if (!isSupabaseConfigured) {
      return
    }

    setCategoriesLoading(true)
    setCategoriesError(null)

    try {
      const nextCategories = await listCategories()
      startTransition(() => {
        setCategories(nextCategories)
        if (!selectedCategory && nextCategories.length > 0) {
          setSelectedCategory(nextCategories[0].category)
        }
      })
    } catch (error) {
      const message =
        error instanceof Error
          ? error.message
          : 'Impossible de charger les categories.'

      setCategoriesError(message)
    } finally {
      setCategoriesLoading(false)
    }
  })

  const syncSession = useEffectEvent(async (silent = false) => {
    if (!sessionCode || !isSupabaseConfigured) {
      return
    }

    try {
      const nextState = await getSessionState(sessionCode, playerToken)
      applySessionState(nextState)
    } catch (error) {
      if (!silent) {
        handleFailure(error)
      } else if (
        error instanceof Error &&
        error.message.includes('SESSION_NOT_FOUND')
      ) {
        handleFailure(error)
      }
    }
  })

  useEffect(() => {
    loadCategories()
  }, [])

  useEffect(() => {
    if (!sessionCode || !isSupabaseConfigured) {
      return
    }

    void syncSession(true)

    const intervalId = window.setInterval(() => {
      void syncSession(true)
    }, POLL_INTERVAL_MS)

    return () => {
      window.clearInterval(intervalId)
    }
  }, [sessionCode])

  useEffect(() => {
    if (!currentQuestion) {
      lastQuestionIdRef.current = null
      setTextDraft('')
      setChoiceDraft(null)
      setScaleDraft(null)
      return
    }

    if (lastQuestionIdRef.current === currentQuestion.id) {
      return
    }

    lastQuestionIdRef.current = currentQuestion.id

    setTextDraft(currentQuestion.selfAnswer?.text ?? '')
    setChoiceDraft(currentQuestion.selfAnswer?.choice ?? null)
    setScaleDraft(
      currentQuestion.selfAnswer?.scale ??
        (currentQuestion.type === 'scale'
          ? Math.round(
              (currentQuestion.scaleMin + currentQuestion.scaleMax) / 2,
            )
          : null),
    )
  }, [currentQuestion])

  useEffect(() => {
    if (!pickRevealData) {
      pickScreenInitializedRef.current = false
      setPickSelection([])
      return
    }

    if (pickRevealData.pickedCountSelf === 0 && pickScreenInitializedRef.current) {
      return
    }

    const preselected = pickRevealData.questions
      .filter((question) => question.selectedBySelf)
      .map((question) => question.id)

    setPickSelection(preselected)
    pickScreenInitializedRef.current = true
  }, [pickRevealData])

  const runAction = async <T,>(
    label: string,
    action: () => Promise<T>,
    onSuccess?: (result: T) => void,
  ) => {
    setBusyLabel(label)
    setScreenError(null)

    try {
      const result = await action()
      onSuccess?.(result)
    } catch (error) {
      handleFailure(error)
    } finally {
      setBusyLabel(null)
    }
  }

  const handleCreateSession = async () => {
    if (!selectedCategory) {
      setScreenError('Choisis une categorie.')
      return
    }

    await runAction('Creation de la session...', async () => {
      const nextState = await createSession(selectedCategory, playerToken)
      applySessionState(nextState)
      setHomeMode('menu')
      return nextState
    })
  }

  const handleJoinSession = async () => {
    const normalizedCode = normalizeCode(joinCode)

    if (normalizedCode.length !== 6) {
      setScreenError('Le code doit contenir 6 caracteres.')
      return
    }

    await runAction('Connexion a la session...', async () => {
      const nextState = await joinSession(normalizedCode, playerToken)
      applySessionState(nextState)
      setJoinCode(normalizedCode)
      setHomeMode('menu')
      return nextState
    })
  }

  const handleReady = async () => {
    if (!sessionCode) {
      return
    }

    await runAction('Signalement pret...', async () => {
      const nextState = await setReady(sessionCode, playerToken)
      applySessionState(nextState)
      return nextState
    })
  }

  const handleSubmitAnswer = async (passed: boolean) => {
    if (!sessionCode || !currentQuestion) {
      return
    }

    if (!passed) {
      if (currentQuestion.type === 'text' && !textDraft.trim()) {
        setScreenError('Ecris une reponse ou passe la question.')
        return
      }

      if (currentQuestion.type === 'qcm' && !choiceDraft) {
        setScreenError('Choisis une option ou passe la question.')
        return
      }

      if (currentQuestion.type === 'scale' && scaleDraft === null) {
        setScreenError('Choisis une valeur ou passe la question.')
        return
      }
    }

    await runAction(
      passed ? 'Question passee...' : 'Envoi de la reponse...',
      async () => {
        const nextState = await submitAnswer({
          code: sessionCode,
          playerToken,
          questionId: currentQuestion.id,
          passed,
          answerText: passed ? null : textDraft.trim() || null,
          answerChoice: passed ? null : choiceDraft,
          answerScale: passed ? null : scaleDraft,
        })
        applySessionState(nextState)
        return nextState
      },
    )
  }

  const handleTogglePick = (question: PickRevealQuestion) => {
    if (question.unavailable && !question.selectedBySelf) {
      return
    }

    setPickSelection((current) => {
      if (current.includes(question.id)) {
        return current.filter((id) => id !== question.id)
      }

      if (current.length >= 3) {
        return current
      }

      return [...current, question.id]
    })
  }

  const handleSaveRevealPicks = async () => {
    if (!sessionCode) {
      return
    }

    if (pickSelection.length !== 3) {
      setScreenError('Choisis exactement 3 questions a reveler.')
      return
    }

    await runAction('Validation des revelations...', async () => {
      const nextState = await pickRevealQuestions(
        sessionCode,
        playerToken,
        pickSelection,
      )
      applySessionState(nextState)
      return nextState
    })
  }

  const handleAdvanceReveal = async () => {
    if (!sessionCode) {
      return
    }

    await runAction('Synchronisation de la revelation...', async () => {
      const nextState = await advanceReveal(sessionCode, playerToken)
      applySessionState(nextState)
      return nextState
    })
  }

  const handleLeaveLocally = () => {
    applySessionState(null)
    setHomeMode('menu')
    setJoinCode('')
    setScreenError(null)
  }

  const renderHome = () => (
    <section className="panel hero-panel">
      <div className="eyebrow">Couples only</div>
      <h1>Mieux se connaitre, sans compte et sans score.</h1>
      <p className="lede">
        Creez une session, repondez chacun de votre cote, puis choisissez
        ensemble quelles verites reveler.
      </p>

      <div className="actions">
        <button className="primary-button" onClick={() => setHomeMode('create')}>
          Creer une session
        </button>
        <button className="secondary-button" onClick={() => setHomeMode('join')}>
          Rejoindre une session
        </button>
      </div>

      {homeMode === 'create' ? (
        <div className="subpanel">
          <div className="section-title">Choisir une categorie</div>

          {categoriesLoading ? (
            <p className="muted">Chargement des categories...</p>
          ) : null}

          {categoriesError ? <p className="error-text">{categoriesError}</p> : null}

          <div className="category-grid">
            {categories.map((category) => (
              <button
                key={category.category}
                className={
                  category.category === selectedCategory
                    ? 'category-card selected'
                    : 'category-card'
                }
                onClick={() => setSelectedCategory(category.category)}
              >
                <span>{category.category}</span>
                <small>{category.count} questions actives</small>
              </button>
            ))}
          </div>

          <div className="actions inline-actions">
            <button
              className="primary-button"
              disabled={busyLabel !== null || categories.length === 0}
              onClick={() => void handleCreateSession()}
            >
              Generer un code
            </button>
            <button
              className="secondary-button"
              onClick={() => setHomeMode('menu')}
            >
              Retour
            </button>
          </div>
        </div>
      ) : null}

      {homeMode === 'join' ? (
        <div className="subpanel">
          <div className="section-title">Entrer un code</div>
          <label className="field">
            <span>Code de session</span>
            <input
              type="text"
              inputMode="text"
              maxLength={6}
              value={joinCode}
              onChange={(event) => setJoinCode(normalizeCode(event.target.value))}
              placeholder="ABCD23"
            />
          </label>

          <div className="actions inline-actions">
            <button
              className="primary-button"
              disabled={busyLabel !== null}
              onClick={() => void handleJoinSession()}
            >
              Rejoindre
            </button>
            <button
              className="secondary-button"
              onClick={() => setHomeMode('menu')}
            >
              Retour
            </button>
          </div>
        </div>
      ) : null}
    </section>
  )

  const renderLobby = () => {
    if (!sessionState) {
      return null
    }

    const partnerJoined = sessionState.presence.partnerJoined
    const selfReady = sessionState.presence.selfReady
    const partnerReady = sessionState.presence.partnerReady

    return (
      <section className="panel flow-panel">
        <div className="session-chip">Code {sessionState.session.code}</div>
        <h2>Lobby</h2>

        <div className="status-card">
          <div>
            <strong>
              {partnerJoined
                ? partnerReady
                  ? 'Partenaire pret'
                  : 'Partenaire connecte'
                : 'En attente du partenaire'}
            </strong>
            <p className="muted">
              {partnerJoined
                ? sessionState.presence.partnerConnected
                  ? 'La session est active. Vous pourrez commencer quand vous serez tous les deux prets.'
                  : 'Le partenaire semble inactif. La session expire apres un court timeout.'
                : 'Partage le code pour rejoindre cette partie.'}
            </p>
          </div>

          <div className="status-pills">
            <span className={selfReady ? 'pill active' : 'pill'}>Toi pret</span>
            <span className={partnerReady ? 'pill active' : 'pill'}>
              Partenaire pret
            </span>
          </div>
        </div>

        <div className="actions inline-actions">
          <button
            className="primary-button"
            disabled={busyLabel !== null || !partnerJoined || selfReady}
            onClick={() => void handleReady()}
          >
            {selfReady ? 'En attente...' : 'Pret'}
          </button>
          <button className="secondary-button" onClick={handleLeaveLocally}>
            Quitter
          </button>
        </div>
      </section>
    )
  }

  const renderQuestionInput = () => {
    if (!currentQuestion) {
      return null
    }

    if (currentQuestion.selfDone) {
      return (
        <div className="waiting-card">
          <strong>Reponse envoyee.</strong>
          <p className="muted">
            Ton partenaire est encore en train de repondre a cette question.
          </p>
        </div>
      )
    }

    if (currentQuestion.type === 'text') {
      return (
        <label className="field">
          <span>Ta reponse</span>
          <textarea
            rows={5}
            value={textDraft}
            onChange={(event) => setTextDraft(event.target.value)}
            placeholder="Ecris sans filtre, l'autre ne voit rien pour l'instant."
          />
        </label>
      )
    }

    if (currentQuestion.type === 'qcm') {
      return (
        <div className="option-list">
          {currentQuestion.options.map((option) => (
            <button
              key={option}
              className={choiceDraft === option ? 'option-card selected' : 'option-card'}
              onClick={() => setChoiceDraft(option)}
            >
              {option}
            </button>
          ))}
        </div>
      )
    }

    return (
      <label className="field">
        <span>
          Ton niveau: {scaleDraft ?? currentQuestion.scaleMin}/
          {currentQuestion.scaleMax}
        </span>
        <input
          type="range"
          min={currentQuestion.scaleMin}
          max={currentQuestion.scaleMax}
          value={scaleDraft ?? currentQuestion.scaleMin}
          onChange={(event) => setScaleDraft(Number(event.target.value))}
        />
      </label>
    )
  }

  const renderQuestionScreen = () => {
    if (!sessionState || !currentQuestion) {
      return null
    }

    return (
      <section className="panel flow-panel">
        <div className="progress-row">
          <span className="session-chip">Question {currentQuestion.position + 1}/10</span>
          <span className="muted">
            {currentQuestion.partnerDone
              ? 'Le partenaire a fini'
              : 'Partenaire en train de repondre...'}
          </span>
        </div>

        <h2>{currentQuestion.prompt}</h2>
        {renderQuestionInput()}

        {!currentQuestion.selfDone ? (
          <div className="actions inline-actions">
            <button
              className="primary-button"
              disabled={busyLabel !== null}
              onClick={() => void handleSubmitAnswer(false)}
            >
              Valider
            </button>
            <button
              className="secondary-button"
              disabled={busyLabel !== null}
              onClick={() => void handleSubmitAnswer(true)}
            >
              Passer
            </button>
          </div>
        ) : null}
      </section>
    )
  }

  const renderPickRevealScreen = () => {
    if (!sessionState || !pickRevealData) {
      return null
    }

    return (
      <section className="panel flow-panel">
        <div className="progress-row">
          <span className="session-chip">Fin de partie</span>
          <span className="muted">
            {pickRevealData.pickedCountPartner >= 3
              ? 'Le partenaire a verrouille ses 3 choix'
              : 'Le partenaire choisit encore'}
          </span>
        </div>

        <h2>Choisis 3 questions du partenaire a reveler</h2>
        <p className="muted">
          Vous revelerez ensuite les reponses une par une, dans le meme ordre pour
          vous deux.
        </p>

        <div className="question-pick-grid">
          {pickRevealData.questions.map((question) => {
            const selected = pickSelection.includes(question.id)
            const className = question.unavailable && !selected
              ? 'pick-card locked'
              : selected
                ? 'pick-card selected'
                : 'pick-card'

            return (
              <button
                key={question.id}
                className={className}
                onClick={() => handleTogglePick(question)}
              >
                <span className="pick-index">{question.position + 1}</span>
                <span>{question.prompt}</span>
              </button>
            )
          })}
        </div>

        <div className="actions inline-actions">
          <button
            className="primary-button"
            disabled={busyLabel !== null || pickSelection.length !== 3}
            onClick={() => void handleSaveRevealPicks()}
          >
            Valider mes 3 choix
          </button>
          <span className="muted">{pickSelection.length}/3 selectionnees</span>
        </div>
      </section>
    )
  }

  const renderRevealScreen = () => {
    if (!sessionState || !revealData?.current) {
      return null
    }

    const currentReveal = revealData.current

    return (
      <section className="panel flow-panel">
        <div className="progress-row">
          <span className="session-chip">
            Revelation {currentReveal.position + 1}/{revealData.total}
          </span>
          <span className="muted">
            {revealData.partnerAcknowledged
              ? 'Le partenaire est pret pour la suivante'
              : 'Le partenaire lit encore'}
          </span>
        </div>

        <h2>{currentReveal.prompt}</h2>

        <div className="reveal-grid">
          <div className="reveal-card">
            <span className="reveal-label">{selfLabel}</span>
            <p>{formatAnswer(currentReveal.answers[sessionState.session.playerSlot])}</p>
          </div>
          <div className="reveal-card accent">
            <span className="reveal-label">{partnerLabel}</span>
            <p>
              {formatAnswer(
                currentReveal.answers[
                  sessionState.session.playerSlot === 'A' ? 'B' : 'A'
                ],
              )}
            </p>
          </div>
        </div>

        <div className="actions inline-actions">
          <button
            className="primary-button"
            disabled={busyLabel !== null || revealData.selfAcknowledged}
            onClick={() => void handleAdvanceReveal()}
          >
            {currentReveal.position + 1 === revealData.total
              ? 'Terminer'
              : 'Suivant'}
          </button>
          {revealData.selfAcknowledged ? (
            <span className="muted">En attente du partenaire...</span>
          ) : null}
        </div>
      </section>
    )
  }

  const renderEndedScreen = () => (
    <section className="panel flow-panel">
      <div className="session-chip">Session terminee</div>
      <h2>Vous avez fini.</h2>
      <p className="lede">
        Aucune note, aucun score. Juste ce qui merite d etre continue hors de
        l ecran.
      </p>
      <div className="actions inline-actions">
        <button className="primary-button" onClick={handleLeaveLocally}>
          Revenir a l accueil
        </button>
      </div>
    </section>
  )

  const renderContent = () => {
    if (!isSupabaseConfigured) {
      return (
        <section className="panel flow-panel">
          <div className="session-chip">Configuration requise</div>
          <h2>Ajoute tes variables d environnement.</h2>
          <p className="muted">
            Cree un fichier <code>.env.local</code> avec
            <code>VITE_SUPABASE_URL</code> et
            <code>VITE_SUPABASE_ANON_KEY</code>, puis colle les scripts SQL fournis
            dans Supabase.
          </p>
        </section>
      )
    }

    if (!sessionState) {
      return renderHome()
    }

    switch (sessionState.session.status) {
      case 'waiting_partner':
      case 'ready':
        return renderLobby()
      case 'in_progress':
        return renderQuestionScreen()
      case 'pick_reveal':
        return renderPickRevealScreen()
      case 'reveal':
        return renderRevealScreen()
      case 'ended':
        return renderEndedScreen()
      default:
        return renderHome()
    }
  }

  return (
    <main className="app-shell">
      <div className="ambient ambient-left" />
      <div className="ambient ambient-right" />

      <section className="frame">
        <header className="topbar">
          <div>
            <div className="brand-mark">COEUR</div>
            <p className="muted">Sessions synchrones a 2, sans compte.</p>
          </div>

          {sessionState ? (
            <button className="ghost-button" onClick={handleLeaveLocally}>
              Effacer la session locale
            </button>
          ) : null}
        </header>

        {screenError ? <div className="banner error">{screenError}</div> : null}
        {busyLabel ? <div className="banner info">{busyLabel}</div> : null}

        {renderContent()}
      </section>
    </main>
  )
}

function normalizeCode(value: string) {
  return value.toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 6)
}

function formatAnswer(answer: AnswerPayload) {
  if (answer.passed) {
    return 'Question passee.'
  }

  if (answer.text) {
    return answer.text
  }

  if (answer.choice) {
    return answer.choice
  }

  if (answer.scale !== null) {
    return `${answer.scale}/5`
  }

  return 'Sans reponse.'
}

export default App
