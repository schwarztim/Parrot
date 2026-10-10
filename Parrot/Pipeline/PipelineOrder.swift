import Foundation

/// The only file that orders the pipeline. `DictationPipeline` instantiates
/// these lists once, in this order, with `init(services:)`.
enum PipelineOrder {

    /// Lifecycle hooks run in this order for every session.
    @MainActor
    static var participants: [any RecordingParticipant.Type] {
        [
            RecorderUIParticipant.self,
            ContextCaptureParticipant.self,
            PlaybackParticipant.self,
            SoundCueParticipant.self,
            LevelMeterParticipant.self,
            RecordingWriterParticipant.self,
            LiveTranscriptionParticipant.self,
            OutputParticipant.self,
            AgentParticipant.self,
        ]
    }

    /// Stages run in this order after the mic closes.
    @MainActor
    static var stages: [any DictationStage.Type] {
        [
            PreprocessAudioStage.self,
            TranscribeStage.self,
            TranscriptCleanupStage.self,
            ReplacementsStage.self,
            RefineStage.self,
            PostRefineReplacementsStage.self,
            AgentRouteStage.self,
            FormatOutputStage.self,
            DeliverStage.self,
            PostActionStage.self,
            PersistStage.self,
        ]
    }
}
