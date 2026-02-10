# NorthStar Vision Assist System: User Manual

Welcome to **NorthStar**, a head-mounted visual assistant designed to help you navigate the world with greater independence and safety. By combining advanced computer vision with audio feedback, NorthStar turns the visual world into a detailed auditory experience.

This guide covers everything from setting up your device to using its advanced navigation and reading features.
## Table of Contents

1. [Getting Started](#getting-started)
2. [Hardware Overview](#hardware-overview)
3. [Wearing the Device](#wearing-the-device)
4. [Operation Modes](#operation-modes)
    * [Navigation Mode](#navigation-mode)
    * [Reading Mode (Text-to-Speech)](#reading-mode-text-to-speech)
    * [Scene Description (RAG)](#scene-description-rag)
5. [Caregiver Features](#caregiver-features)
6. [Privacy & Security](#privacy--security)
7. [FAQ & Troubleshooting](#faq--troubleshooting)

---

## Getting Started

NorthStar is designed to be affordable and easy to use. Before using the device for the first time, please ensure you have all the necessary components and that the battery is fully charged.

### What's in the Box?

* **NorthStar Headset:** The main frame containing the camera and sensors.
* **Processing Unit:** A portable unit (Raspberry Pi) that powers the AI.
* **Audio Output Module:** Headphones or bone-conduction speakers for audio feedback.
The system consists of three main parts working together:

1. **Vision Goggles (Input):** Located on the headset, this includes the camera and sensors that capture the environment around you.
2. **Processing Unit:** This compact computer runs the artificial intelligence models. It processes images locally and remotely via a web server to identify objects and read text.
3. **Audio Output (Output):** This converts the visual data into spoken words. You will hear descriptions of objects, people, and text through your headphones.
> **Note:** The device is designed to be unobtrusive and comfortable for long-term wear.

---

## Wearing the Device

1. **Fit the Headset:** Place the goggles over your eyes. Adjust the strap for a snug but comfortable fit.
2. **Power On:** Press the power button on the Processing Unit. You should hear a startup chime or voice prompt indicating the system is booting up.

---

## Operation Modes

NorthStar offers different modes to assist you in various situations.

### Navigation Mode

This is the default mode. The system uses **Object Detection** to identify obstacles and items in your path.

* **How it works:** The camera scans your surroundings in real-time.

**What you hear:** Short, clear audio cues such as "Chair ahead," "Person approaching," or "Table on right".

**Goal:** To help you move around safely and independently without colliding with obstacles.

### Reading Mode (Text-to-Speech)

Use this mode to read signs, menus, or documents.

* **How to activate:** Press the button on the right side of the Processing Unit to activate Reading Mode.

**Function:** The system uses Optical Character Recognition (OCR) to detect text in the camera's view.
 
**What you hear:** The device will read aloud the text it sees, such as "Exit Sign" or items on a restaurant menu.



### Scene Description (RAG)

For a more detailed understanding of your environment, use the Scene Description mode. This uses **Retrieval-Augmented Generation (RAG)** to provide context-aware details.
 
**How it works:** Unlike standard detection which names objects, this mode retrieves contextual information from a database.
 
**Example:** Instead of just saying "Bottle," it might say, "This is your personal water bottle located on the desk".


* **Best for:** Understanding complex scenes or identifying personal items.

### Phone Connection

NorthStar is designed to leverage the device you already carry every day. Instead of relying on heavy, standalone processors, the system connects directly to your smartphone, which acts as the central processing unit (CPU).

* **Smartphone as the Brain:** By connecting the headset to your mobile device (via USB-C or wireless connection), NorthStar utilizes your phone's powerful processor to run the AI object detection and RAG models in real-time.
* **Resource Efficiency:** Offloading processing to the phone reduces the weight of the headset and eliminates the need for a separate battery pack or microcontroller unit.
* **Seamless Connectivity:** The system automatically uses your phone's existing cellular or Wi-Fi connection to retrieve context from the database and process complex scene descriptions without additional setup.

---

## Privacy & Security

We understand that a device with a camera raises privacy concerns. NorthStar is built with **Ethical and Security Constraints** in mind.

* **Local Processing:** Whenever possible, images are processed locally on the device rather than being sent to the cloud. This ensures your visual data remains private.
 
**Data Security:** Any stored information, such as user preferences or personal object databases, is secured to prevent misuse.

---

## FAQ & Troubleshooting

### Frequently Asked Questions

**Q: Does NorthStar require an internet connection?**
A: Basic Navigation Mode works locally. However, advanced features like RAG (Scene Description) may require internet access to retrieve context from the database.

**Q: How long does the battery last?**
A: Battery life depends on usage, but we optimize our software to ensure performance on cost-effective, portable hardware.

**Q: Is the audio feedback overwhelming?**
A: No. We carefully calibrate the audio feedback to be helpful without being overwhelming or distracting. You can customize the level of detail in the settings.

### Troubleshooting

* **Issue: Audio is delayed.**
  * **Cause:** Latency in the system processing.
  * **Fix:** Ensure the Processing Unit is not overheating and has sufficient battery. Restart the device to clear temporary memory.

* **Issue: System is not recognizing objects.**
  * **Cause:** Poor lighting or obstructed camera.
  * **Fix:** Ensure the camera lens is clean and that you are in a well-lit environment.

* **Issue: Text reading is inaccurate.**
  * **Cause:** The text might be too far away or stylized.
  * **Fix:** Try to hold the text steady and closer to the camera.





For further assistance, please contact the development team or your system administrator.
