# NorthStar: Task List
**Members:** Christian Graber, Jared Walden, Viet Ton, Mohamed Elmogaber

### Christian – API Designer / Software Lead
 - Define the desired system architectural plan and API endpoints/ processing medium (explore using phones for image processing) for communication with the module.
 - Implement REST or gRPC APIs for vision to RAG and RAG to audio interactions.
 - Ensure a semi-modular integration across hardware, AI, and user interface.
 - Establish the CI/CD pipeline with versioning and very basic testing (will try to encourage test driven development).
 - Oversee the code quality, documentation, and ensure use of best practice.

### Jared – Hardware + Model / UX Design
 - Select microcontroller/embedded platform (e.g., Raspberry Pi, Jetson Nano).
 - Prototype glasses hardware (cameras, speakers, layout, frame).
 - Design wearable model/ frame.
 - Design and develop user interface system (voice commands, touchpad, or buttons).
 - Conduct user testing sessions to refine ergonomics and usability (explore using student body as test subjects).

### Viet – RAG Integration
 - Design and build a database of objects and environmental context for retrieval.
 - Implement RAG pipeline that augments vision outputs with additional context.
 - Connect vision module (Mohamed’s output) to the RAG system for dynamic querying.
 - Optimize retrieval latency to help the response be delivered efficiently.
 - Evaluate RAG responses with test cases to optimize system.

### Mohamed – Computer Vision Functionality
 - Research and build object detection/scene description models suitable for real-time use.
 - Implement text detection and OCR for reading signs, menus, and documents.
 - Develop real-time scene captioning pipeline (detect + describe).
 - Optimize computer vision models for embedded hardware to improve processing time and battery load.
 - Integrate multi-modal outputs (object detection + text reading) into a unified vision module for clean user experience.