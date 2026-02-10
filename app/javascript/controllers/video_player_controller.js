import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="video-player"
export default class extends Controller {
  static targets = ["video"]
  static values = { startTime: Number }

  connect() {
    // Initialize Video.js on the video element
    if (typeof videojs !== "undefined" && this.hasVideoTarget) {
      this.player = videojs(this.videoTarget, {
        fluid: true
      })

      // Seek to start time and auto-play if provided
      if (this.hasStartTimeValue && this.startTimeValue > 0) {
        const startTime = this.startTimeValue
        this.player.one("loadedmetadata", () => {
          this.player.currentTime(startTime)
          this.player.play()
        })
      }
    }
  }

  disconnect() {
    // Dispose of Video.js player when navigating away
    if (this.player) {
      this.player.dispose()
    }
  }
}
