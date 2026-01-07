import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "menu"]

  connect() {
    this.closeOnClickOutside = this.closeOnClickOutside.bind(this)
  }

  toggle() {
    if (this.menuTarget.classList.contains("hidden")) {
      this.open()
    } else {
      this.close()
    }
  }

  open() {
    this.menuTarget.classList.remove("hidden")
    this.buttonTarget.setAttribute("aria-expanded", "true")
    this.positionMenu()
    document.addEventListener("click", this.closeOnClickOutside)
  }

  positionMenu() {
    const buttonRect = this.buttonTarget.getBoundingClientRect()
    const viewportHeight = window.innerHeight

    // Use fixed positioning to escape overflow containers
    this.menuTarget.style.position = "fixed"
    this.menuTarget.style.right = `${window.innerWidth - buttonRect.right}px`

    // Remove relative positioning classes
    this.menuTarget.classList.remove("mt-6", "bottom-full", "mb-1", "absolute")

    // Temporarily show to measure height
    const menuHeight = this.menuTarget.offsetHeight
    const spaceBelow = viewportHeight - buttonRect.bottom

    if (spaceBelow < menuHeight + 20) {
      // Open upward
      this.menuTarget.style.top = `${buttonRect.top - menuHeight - 4}px`
    } else {
      // Open downward
      this.menuTarget.style.top = `${buttonRect.bottom + 4}px`
    }
  }

  close() {
    this.menuTarget.classList.add("hidden")
    this.buttonTarget.setAttribute("aria-expanded", "false")
    document.removeEventListener("click", this.closeOnClickOutside)
  }

  closeOnClickOutside(event) {
    if (!this.element.contains(event.target)) {
      this.close()
    }
  }

  disconnect() {
    document.removeEventListener("click", this.closeOnClickOutside)
  }
}
