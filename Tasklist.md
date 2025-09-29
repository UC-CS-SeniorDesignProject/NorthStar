# NorthStar: Task List
**Members:** Christian Graber, Jared Walden, Viet Ton, Mohamed Elmogaber

### Christian – API Designer / Software Lead
 - Define the desired system architectural plan and API endpoints for communication with the module.
 - Implement REST or gRPC APIs for vision to RAG and RAG to audio interactions.
 - Ensure a semi-modular integration across hardware, AI, and user interface.
 - Establish the CI/CD pipeline with versioning and very basic automated testing.
 - Oversee the code quality, documentation, and ensure use of software best practices.

### Jared – Hardware + Model / UX Design
 - Select microcontroller/embedded platform (e.g., Raspberry Pi, Jetson Nano).
 - Prototype glasses hardware (cameras, speakers, layout).
 - Design wearable model (fit, weight distribution, accessibility).
 - Develop user input system (voice commands, touchpad, or buttons).
 - Conduct user testing sessions to refine ergonomics and usability.

### Viet – RAG Integration
 - Build a database of objects and environmental context for retrieval.
 - Implement RAG pipeline that augments vision outputs with additional context.
 - Connect vision module (Mohamed’s output) to the RAG system for dynamic querying.
 - Optimize retrieval latency to help the response delivered efficiently.
 - Evaluate RAG responses with test cases.

### Mohamed – Computer Vision Functionality
 - Research and build object detection/scene description models suitable for real-time glasses use.
 - Implement text detection and OCR for reading signs, menus, and documents.
 - Develop real-time scene captioning pipeline (detect + describe).
 - Optimize computer vision models for embedded hardware (quantization, pruning).
 - Integrate multi-modal outputs (object detection + text reading) into a unified vision module.
