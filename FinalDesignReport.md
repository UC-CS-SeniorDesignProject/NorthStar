# NorthStar Final Design Report

## Table of Contents
1. [Project Description](#1-project-description)
2. [User Interface Specification](#2-user-interface-specification)
3. [Testing Methodology and Iterative Results](#3-testing-methodology-and-iterative-results)
4. [User Manual](#4-user-manual)
5. [Presentations](#5-presentations)
6. [Final Expo Poster](#6-final-expo-poster)
7. [Assessments](#7-assessments)
8. [Summary of Hours and Justification](#8-summary-of-hours-and-justification)
9. [Summary of Expenses](#9-summary-of-expenses)
10. [Appendix](#10-appendix)

---

## 1. Project Description

**Abstract**
NorthStar is a wearable visual assist system helping visually impaired users navigate safely. A camera-equipped Radxa Zero 3W captures environmental data, processing it via a multi-model AI pipeline utilizing computer vision and RAG. It evaluates spatial awareness, depth, and scene context to deliver real-time auditory guidance through an iOS text-to-speech app.

**Full Description**
The NorthStar vision assist system is designed to help visually impaired users navigate their environments safely and independently. The system captures visual data through a hardware interface, processes it using an advanced artificial intelligence pipeline, and generates auditory feedback in real-time. 

Initially relying on basic object detection, the server architecture was extensively upgraded to support a robust multi-model pipeline. The system now integrates YOLOv12x for object detection, EasyOCR for text recognition, Depth Anything v2 for distance estimation, and Florence-2-base for scene description. A local Large Language Model (Qwen2.5) dynamically combines these inputs with an expanded Retrieval-Augmented Generation (RAG) knowledge base to provide the user with spatial, depth, motion, and contextual awareness.

---

## 2. User Interface Specification

The primary interface for NorthStar is a native iOS application engineered for automated, hands-free operation. The UI is divided into a two-tab layout to separate user-facing features from developer testing environments.

* **Home Dashboard:** Functions as the main user hub featuring auto-capture controls, live system status, and a frosted glass guidance card displaying the latest spoken text.
* **On-Demand OCR:** Includes accessible buttons directly on the dashboard to read text from the latest captured image or pull a fresh capture from the glasses.
* **Tools Menu:** A dedicated section for developers featuring testing pages, performance statistics, latency tracking, and configuration options.
* **Background Audio Configuration:** The application utilizes background audio sessions to ensure text-to-speech guidance continues uninterrupted while the user's phone is locked.

---

## 3. Testing Methodology and Iterative Results

Rather than relying on isolated, simulated unit tests, the NorthStar system was validated through **Iterative Experiential Testing**. Because the project is a wearable device heavily reliant on real-world environmental factors (lighting, motion, network latency), testing was conducted by actively wearing the prototype and using real-time feedback to continuously refine the hardware, server architecture, and iOS application.

### Key Testing Phases & Feedback Loops

* **Environmental & Object Detection Testing:** Live demo testing revealed that raw bounding-box detection was insufficient for a visually impaired user. The system initially lacked depth awareness and repeatedly announced the same objects. 
    * *Result:* This feedback drove the integration of Depth Anything v2 (for distance estimation in feet), a 5-zone directional system, and a 5-second object cooldown to prevent auditory spam.
* **OCR Pipeline Validation:** Real-world testing of the OCR capabilities uncovered critical CUDA/PyTorch DLL conflicts with the initial PaddleOCR engine on the Windows server.
    * *Result:* The team successfully pivoted to EasyOCR on the server and integrated Apple Vision framework fallbacks natively on the iOS app to ensure high availability.
* **Latency and Network Stress Testing:** Using the iOS app's custom `LatencyMonitor` and `ActivityLog` ring buffers, the team tracked real-time ping statistics (Current, Min, Max, P95) between the Radxa glasses and the processing server.
    * *Result:* Network stress testing led to the implementation of an Adaptive Capture Rate, which adjusts the capture interval based on network aggressiveness, and a graceful auto-pause feature that stops the capture loop after 5 consecutive network failures to prevent app crashes.
* **Guidance & TTS (Text-to-Speech) Refinement:** Listening to the generated guidance during live walks proved that simple concatenated strings ("Object A. Object B.") sounded too robotic. 
    * *Result:* Testing directly influenced the implementation of a local LLM (Qwen2.5) to dynamically combine alerts into natural, conversational guidance, capped at 200 characters to prevent TTS cutoff.

### Resolved System Anomalies (Demo Testing Outcomes)

| Identified Issue (During Live Demo) | Implemented Resolution |
|-------------------------------------|------------------------|
| **Repetitive Announcements:** The same object was announced every frame. | Implemented a 5-second cooldown per object label. |
| **Vague Proximity:** System only announced objects as "nearby." | Integrated depth mapping to provide accurate distance (e.g., "about 5 feet"). |
| **Robotic Output:** "Template" speech lacked context. | Migrated to dynamic LLM response generation for natural phrasing. |
| **Connection Spam:** Server disconnects caused UI error spam. | Added a 5-failure threshold that triggers a graceful auto-pause and haptic warning. |

---

## 4. User Manual

`https://mailuc-my.sharepoint.com/:b:/g/personal/waldenjd_mail_uc_edu/IQCr4y4PDIX7S5cQe1BXnLiFAVnDtdCx8IGBKoHcxG3yEK0?e=8SL1Y3`

### Frequently Asked Questions (FAQ)

**Q: How do I connect the app to the glasses and server?**
A: The app scans the network on launch and automatically discovers both the Radxa glasses and the processing server via mDNS and subnet scanning.

**Q: Do I need to manually trigger object detection?**
A: No, when both devices connect, the capture loop starts automatically. The app will capture, process, and speak guidance continuously. 

**Q: What happens if the server loses connection?**
A: The app tracks latency and connection status. If the primary processing server is unavailable, the app can fall back to Apple Vision on-device processing. If 5 consecutive errors occur, the system safely auto-pauses until the connection is restored.

*(Include screenshots of the app dashboard and settings here)*

---

## 5. Presentations

* **Spring Final PPT Presentation:** `https://github.com/UC-CS-SeniorDesignProject/NorthStar/blob/main/presentations/CS%20SD2%20Presentation%202nd%20Semester.pptx `
* **Fall SD1 Presentation:** `https://github.com/UC-CS-SeniorDesignProject/NorthStar/blob/main/presentations/CS%20SD2%20Presentation.pptx`

---

## 6. Final Expo Poster

* **Final Expo Poster PDF:** `https://drive.google.com/file/d/1buJub8xkRfb7coLj3-HRbsdmNBRHIXBj/view?usp=sharing `

---

## 7. Assessments

### Initial Self-Assessment (Fall Semester)
The preliminary goal of this project was to apply academic concepts in software engineering and artificial intelligence to a practical application. Acting as the API Designer and Software Lead, the focus was centered on architecting responsive data pathways and designing robust RESTful APIs to connect the hardware interface, vision models, RAG integration, and the database. Drawing from previous co-op experiences in Agile methodologies, the objective was to lead the software architecture to ensure a responsive, real-time user experience.

### Final Self-Assessment (Spring Semester)
The team successfully developed the foundation of the NorthStar system through a highly collaborative and modular Agile strategy. A robust API framework was successfully produced to allow seamless communication across diverse technologies. Significant technical challenges were overcome regarding the balance of fast, low-latency performance with the constraints of cost-effective hardware, requiring constant refinement of the server architecture and detection models based on experiential testing feedback.

---

## 8. Summary of Hours and Justification

### **Project Total Hours:** ~45 Hours per Member

---

### **Christian Graber (API Designer & Software Lead)**
- **Fall Hours:** 18  
- **Spring Hours:** 27  
- **Total:** 45  

**Justification:**  
Led the design of the core software architecture. Developed the remote server, implemented and tested OCR and object detection models, and defined production-ready APIs for the hardware interface, vision models, and database.

---

### **Mohamed Elmogaber (Hardware & Capture Pipeline Lead)**
- **Fall Hours:** 15  
- **Spring Hours:** 30  
- **Total:** 45  

**Justification:**  
Built the Radxa server and image capture pipeline. Designed and 3D-printed the physical glasses hardware, bridging the software system with real-world deployment.

---

### **Jared Walden (Mobile & Systems Integration)**
- **Fall Hours:** 12  
- **Spring Hours:** 30  
- **Total:** 42  

**Justification:**  
Developed the native iOS application using Swift, handling network discovery, latency monitoring, and integrating the text-to-speech feedback loop for real-time user interaction.

---

### **Viet Ton (AI & RAG Integration Lead)**
- **Fall Hours:** 10  
- **Spring Hours:** 35  
- **Total:** 45  

**Justification:**  
Led the integration of the Retrieval-Augmented Generation (RAG) pipeline, enabling context-aware auditory descriptions and improving overall system intelligence.

## 9. Summary of Expenses

| Item                         | Estimated Cost |
|-----------------------------|----------------|
| Radxa Zero 3W Boards & Cameras | ~$200         |
| 3D Printing Materials       | $30            |
| Apple Air M1                | $300           |
| Miscellaneous Costs         | $200           |
| **Total**                   | **~$730**      |

---

## 10. Appendix

* **Code Repositories:** * NorthStar Server: `https://github.com/UC-CS-SeniorDesignProject/NorthStar`
  * NorthStar iOS App: `https://github.com/JaredWalden00/northstarswift`
