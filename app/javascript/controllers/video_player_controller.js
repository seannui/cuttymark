import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="video-player"
export default class extends Controller {
  static targets = ["video"]

  connect() {
    // Initialize Video.js on the video element
    if (typeof videojs !== "undefined" && this.hasVideoTarget) {
      this.player = videojs(this.videoTarget, {
        fluid: true
      })
    }
  }

  disconnect() {
    // Dispose of Video.js player when navigating away
    if (this.player) {
      this.player.dispose()
    }
  }
}
