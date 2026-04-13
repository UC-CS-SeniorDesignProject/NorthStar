class MockVision:
    SCENES = [
        "You are approaching a crosswalk with moving cars.",
        "Indoor hallway with stairs going down.",
        "Crowded sidewalk with people walking in multiple directions.",
        "Dimly lit parking garage.",
    ]

    def __init__(self):
        self.index = 0

    def next_scene(self) -> str:
        scene = self.SCENES[self.index]
        self.index = (self.index + 1) % len(self.SCENES)
        return scene