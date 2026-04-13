import argparse
from config import (
    KNOWLEDGE_BASE_PATH,
    USER_PROFILE_DIR,
    DEFAULT_PROFILE,
    DEFAULT_TOP_K,
)
from rag.rag_module import RAGModule
from vision.mock_vision import MockVision


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--mode", choices=["retrieve", "rag", "mockvision"], default="rag"
    )
    parser.add_argument("--profile", default=DEFAULT_PROFILE)
    parser.add_argument("--top-k", type=int, default=DEFAULT_TOP_K)
    parser.add_argument("--steps", type=int, default=5)
    args = parser.parse_args()

    rag = RAGModule(KNOWLEDGE_BASE_PATH, USER_PROFILE_DIR, args.top_k)

    try:
        rag.load_user_profile(args.profile)
    except FileNotFoundError:
        pass

    if args.mode == "retrieve":
        while True:
            q = input("Query> ").strip()

            if q.lower() in ["exit", "quit", "q"]:
                print("Exiting retrieval mode.")
                break

            responses = rag.retrieve(q)
            combined = rag.combine_responses(responses)
            print(combined)

    elif args.mode == "rag":
        while True:
            scene = input("Scene> ").strip()

            if scene.lower() in ["exit", "quit", "q"]:
                print("Exiting RAG mode.")
                break

            answer, responses = rag.generate_response(scene)

            print("\nASSISTANT:")
            print(answer)

            print("\nMATCHES:")
            for r in responses:
                print(f"- {r}")

    elif args.mode == "mockvision":
        vision = MockVision()
        for _ in range(args.steps):
            scene = vision.next_scene()
            answer, responses = rag.generate_response(scene)

            print(f"\nSCENE: {scene}")
            print(f"GUIDANCE: {answer}")
            print("MATCHES:")
            for r in responses:
                print(f"- {r}")


if __name__ == "__main__":
    main()
